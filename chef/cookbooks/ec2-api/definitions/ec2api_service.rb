# Copyright 2016 SUSE Linux GmbH, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

define :ec2api_service do
  ec2_service_name = "ec2-#{params[:name]}"
  ec2_name = ec2_service_name
  ec2_name = "openstack-ec2-#{params[:name]}"\
                if [rhel, suse].include? node[:platform_family]

  package ec2_name if [rhel, suse].include? node[:platform_family]

  service ec2_service_name do
    service_name ec2_name
    supports status: true, restart: true
    action [:enable, :start]
    subscribes :restart, resources(template: "/etc/ec2api/ec2api.conf")
  end
end
