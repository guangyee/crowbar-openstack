module KeystoneHelper
  def self.service_URL(protocol, host, port)
    "#{protocol}://#{host}:#{port}"
  end

  def self.versioned_service_URL(protocol, host, port, version)
    unless version.start_with?("v")
      version = "v#{version}"
    end
    service_URL(protocol, host, port) + "/" + version + "/"
  end

  def self.admin_auth_url(node, admin_host)
    service_URL(node[:keystone][:api][:protocol], admin_host, node[:keystone][:api][:admin_port])
  end

  def self.public_auth_url(node, public_host)
    versioned_service_URL(node[:keystone][:api][:protocol],
                          public_host,
                          node[:keystone][:api][:service_port],
                          node[:keystone][:api][:version])
  end

  def self.internal_auth_url(node, admin_host)
    versioned_service_URL(node[:keystone][:api][:protocol],
                          admin_host,
                          node[:keystone][:api][:service_port],
                          node[:keystone][:api][:version])
  end

  def self.unversioned_internal_auth_url(node, admin_host)
    service_URL(node[:keystone][:api][:protocol], admin_host, node[:keystone][:api][:service_port])
  end

  # NOTE(gyee): trusted_dashboard in Keystone can be multiple URLs.
  # For example, in a typical production deployment, there can be multiple
  # Horizon endpoints, depending on where Horizon is being accessed. For
  # example, the endpoint for access inside the firewall could be different
  # from the one that is outside of the firewall. And in some cases, the
  # endpoint could be the corporate HTTP proxy.
  # For now, we are prepopulating one that is only understood by Crowbar for
  # testing/demo purpopses. In a production environment, it can be amended with
  # other external endpoints.
  def self.dashboard_public_url(dashboard_node)
    ha_enabled = dashboard_node[:horizon][:ha][:enabled]
    ssl_enabled = dashboard_node[:horizon][:apache][:ssl]
    want_fqdn = true
    public_fqdn = CrowbarHelper.get_host_for_public_url(
      dashboard_node,
      ssl_enabled,
      ha_enabled,
      want_fqdn
    )

    protocol = "http"
    protocol = "https" if ssl_enabled

    "#{protocol}://#{public_fqdn}"
  end

  def self.websso_enabled(node)
    node[:keystone][:federation][:openidc][:enabled]
  end

  def self.trusted_dashboard_url(node)
    # NOTE(gyee): since Horizon is depended on Keystone and will be deployed
    # after Keystone, the Horizon node may not be available when Keystone
    # is first deployed. However, chef executes the recipes periodically.
    # On the next chef run after, after Horizon had deployed, we should be
    # able to figure out the trusted_dashboard from the node, assuming Horizon
    # is always deployed on the same node as Keystone. Otherwise, we'll need
    # to do node search.

    horizon_server = CrowbarUtilsSearch.node_search_with_cache(node, "roles:horizon-server").first

    unless horizon_server.nil?
      horizon_url =
        if horizon_server["horizon"].key?("apache")
          ::File.join(dashboard_public_url(horizon_server), "/auth/websso/")
        else
          ""
        end
    end

    horizon_url
  end

  def self.trusted_dashboards(node)
    # NOTE(gyee): if user does not specify any trusted_dashboards, we'll
    # automagically generate one based on the current knowned crowbar
    # configuration.
    if node[:keystone][:federation][:trusted_dashboards].empty?
      node[:keystone][:federation][:trusted_dashboards] << trusted_dashboard_url(node)
    end

    node[:keystone][:federation][:trusted_dashboards]
  end

  # NOTE(gyee): for some WebSSO protocols (i.e. saml, openidc, etc), the
  # authentication process involves redirecting the browser to the identity
  # provider's endpoint for authentication, then the user is redirected back
  # to Keystone upon successfully authentication with the identity provider.
  # Therefore, the Keystone redirect URL must be external or public as it needs
  # to be accessible by the browsers. Also, in some cases, the URL needs to be
  # fully qualified. For example, Google OpenID Connection requires the URL to
  # be FQDN instead of IP as it must match the authorized domain. Therefore,
  # the WEBSSO_KEYSTONE_URL in Horizon should contain the FQDN, depending
  # on the identity provider. For production deployments, we offers the user
  # the ability to override it because we don't know the user's network
  # topology beforehand. For example, the external endpoint could be handled
  # by an HTTP proxy which may not be known to crowbar.
  def self.websso_keystone_url(node)
    ha_enabled = node[:keystone][:ha][:enabled]
    ssl_enabled = node["keystone"]["api"]["protocol"] == "https"
    want_fqdn = true
    public_fqdn = CrowbarHelper.get_host_for_public_url(node, ssl_enabled, ha_enabled, want_fqdn)

    websso_keystone_url =
      if node[:keystone][:federation][:websso_keystone_url].empty?
        # Will use the one automagically generated by crowbar if user doesn't
        # explicitly set one. This should be for testing/demo purposes in most
        # cases.
        public_auth_url(node, public_fqdn)
      else
        node[:keystone][:federation][:websso_keystone_url]
      end
    websso_keystone_url
  end

  def self.keystone_settings(current_node, cookbook_name)
    instance = current_node[cookbook_name][:keystone_instance] || "default"

    # Cache the result for each cookbook in an instance variable hash. This
    # cache needs to be invalidated for each chef-client run from chef-client
    # daemon (which are all in the same process); so use the ohai time as a
    # marker for that.
    if @keystone_settings_cache_time != current_node[:ohai_time]
      if @keystone_settings
        Chef::Log.info("Invalidating keystone settings cache " \
                       "on behalf of #{cookbook_name}")
      end
      @keystone_settings = nil
      @keystone_node = nil
      cache_reset
      @keystone_settings_cache_time = current_node[:ohai_time]
    end

    unless @keystone_settings && @keystone_settings.include?(instance)
      node = search_for_keystone(current_node, instance)

      ha_enabled = node[:keystone][:ha][:enabled]
      use_ssl = node["keystone"]["api"]["protocol"] == "https"
      public_host = CrowbarHelper.get_host_for_public_url(node, use_ssl, ha_enabled)
      admin_host = CrowbarHelper.get_host_for_admin_url(node, ha_enabled)

      has_default_user = node["keystone"]["default"]["create_user"]
      default_domain = "Default"
      default_domain_id = "default"
      @keystone_settings ||= Hash.new
      @keystone_settings[instance] = {
        "api_version" => node[:keystone][:api][:version],
        # This is somehwat ugly but the Juno keystonemiddleware expects the
        # version to be a "v3.0" for the v3 API instead of the "v3" or "3" that
        # is used everywhere else.
        "api_version_for_middleware" => "v%.1f" % node[:keystone][:api][:version],
        "admin_auth_url" => admin_auth_url(node, admin_host),
        "public_auth_url" => public_auth_url(node, public_host),
        "websso_keystone_url" => websso_keystone_url(node),
        "internal_auth_url" => internal_auth_url(node, admin_host),
        "unversioned_internal_auth_url" => unversioned_internal_auth_url(node, admin_host),
        "use_ssl" => use_ssl,
        "endpoint_region" => node["keystone"]["api"]["region"],
        "insecure" => use_ssl && node[:keystone][:ssl][:insecure],
        "protocol" => node["keystone"]["api"]["protocol"],
        "public_url_host" => public_host,
        "internal_url_host" => admin_host,
        "service_port" => node["keystone"]["api"]["service_port"],
        "admin_port" => node["keystone"]["api"]["admin_port"],
        "admin_token" => node["keystone"]["service"]["token"],
        "admin_project" => node["keystone"]["admin"]["project"],
        "admin_tenant" => node["keystone"]["admin"]["project"],
        "admin_user" => node["keystone"]["admin"]["username"],
        "admin_domain" => default_domain,
        "admin_domain_id" => default_domain_id,
        "admin_password" => node["keystone"]["admin"]["password"],
        "default_project" => node["keystone"]["default"]["project"],
        "default_tenant" => node["keystone"]["default"]["project"],
        "default_user" => has_default_user ? node["keystone"]["default"]["username"] : nil,
        "default_user_domain" => has_default_user ? default_domain : nil,
        "default_user_domain_id" => has_default_user ? default_domain_id : nil,
        "default_password" => has_default_user ? node["keystone"]["default"]["password"] : nil,
        "service_project" => node["keystone"]["service"]["project"],
        "service_tenant" => node["keystone"]["service"]["project"],
        "websso_enabled" => websso_enabled(node),
        "trusted_dashboards" => trusted_dashboards(node)
      }
    end

    @keystone_settings[instance].merge(
      "service_user" => current_node[cookbook_name][:service_user],
      "service_password" => current_node[cookbook_name][:service_password])
  end

  def self.profiler_settings(current_node, cookbook_name)
    instance = current_node[cookbook_name][:keystone_instance] || "default"
    node = search_for_keystone(current_node, instance)
    node["keystone"]["osprofiler"]
  end

  private_class_method def self.search_for_keystone(node, instance)
    if @keystone_node && @keystone_node.include?(instance)
      Chef::Log.info("Keystone server found at #{@keystone_node[instance].name} [cached]")
      return @keystone_node[instance]
    end

    nodes, = Chef::Search::Query.new.search(
      :node,
      "roles:keystone-server" \
      " AND keystone_config_environment:keystone-config-#{instance}" \
      " AND NOT state:crowbar_upgrade"
    )

    if nodes.first
      keystone_node = nodes.first
      keystone_node = node if keystone_node.name == node.name
    else
      keystone_node = node
    end

    @keystone_node ||= Hash.new
    @keystone_node[instance] = keystone_node

    Chef::Log.info("Keystone server found at #{@keystone_node[instance].name}")
    return @keystone_node[instance]
  end

  def self.cache
    @cache
  end

  def self.cache_update(update)
    @cache = @cache.merge(update)
  end

  def self.cache_reset
    @cache = {}
  end

  class KeystoneSession
    def initialize(auth, host, port, protocol, insecure)
      # Need to require net/https so that Net::HTTP gets monkey-patched
      # to actually support SSL:
      use_ssl = protocol == "https"
      require "net/https" if use_ssl
      @http = Net::HTTP.new(host, port)
      @http.use_ssl = use_ssl
      @http.verify_mode = OpenSSL::SSL::VERIFY_NONE if insecure
      @headers = { "Content-Type" => "application/json" }
      @headers["X-Auth-Token"] = get_token(auth)
    end

    def get(path)
      retry_request("GET", path, nil)
    end

    def post(path, body)
      retry_request("POST", path, body)
    end

    def put(path, body)
      retry_request("PUT", path, body)
    end

    def patch(path, body)
      retry_request("PATCH", path, body)
    end

    def delete(path, headers = {})
      retry_request("DELETE", path, nil, headers)
    end

    def authenticated?
      @headers["X-Auth-Token"] != nil
    end

    def revoke_token
      headers = { "X-Subject-Token" => @headers["X-Auth-Token"] }
      delete("/v3/auth/tokens", headers)
    end

    private

    def get_token(auth)
      path = "/v3/auth/tokens"
      resp = post(path, auth_body(auth))
      if resp.is_a?(Net::HTTPSuccess)
        resp["X-Subject-Token"]
      else
        msg = "Failed to get token for User '#{auth[:user]}'"
        msg += " Project '#{auth[:project]}'" if auth[:project]
        Chef::Log.info msg
        Chef::Log.info "Response Code: #{resp.code}"
        Chef::Log.info "Response Message: #{resp.message}"
        nil
      end
    end

    def auth_body(auth)
      body = {
        auth: {
          identity: {
            methods: ["password"],
            password: {
              user: {
                name: auth[:user],
                password: auth[:password],
                domain: {
                  name: auth[:user_domain] || "Default"
                }
              }
            }
          }
        }
      }
      if auth[:project]
        scope = {
          project: {
            name: auth[:project],
            domain: {
              name: auth[:project_domain] || "Default"
            }
          }
        }
        body[:auth][:scope] = scope
      end
      body
    end

    def retry_request(method, path, body, headers = {}, times = nil)
      headers = @headers.merge(headers)
      resp = nil
      (times || 10).times do |count|
        resp = @http.send_request(method, path, body ? JSON.generate(body) : nil, headers)
        break unless resp.is_a?(Net::HTTPServerError)
        Chef::Log.debug("Retrying request #{method} #{path} : #{count}")
        sleep 5
      end
      resp
    end
  end

  def self.session(auth, host, port, protocol, insecure)
    @session ||= KeystoneSession.new(auth, host, port, protocol, insecure)
  end

  def self.reset_session
    @session.revoke_token
    @session = nil
  end
end
