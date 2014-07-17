# Encoding: utf-8
#
# Cookbook Name:: nodestack
# Recipe:: default
#
# Copyright 2014, Rackspace Hosting
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

include_recipe 'chef-sugar'

case node['platform_family']
when 'rhel', 'fedora'
  include_recipe 'yum'
else
  node.set['apt']['compile_time_update'] = true
  include_recipe 'apt'
end

node.set['nodejs']['install_method'] = 'source'
node.set['build-essential']['compile_time'] = 'source'
%w(nodejs::nodejs_from_source nodejs::npm_from_source git build-essential platformstack::monitors platformstack::iptables apt).each do |recipe|
  include_recipe recipe
end

mysql_node = search('node', 'recipes:nodestack\:\:mysql_master' << " AND chef_environment:#{node.chef_environment}").first
mongo_node = search('node', 'recipes:nodestack\:\:mongodb_standalone' << " AND chef_environment:#{node.chef_environment}").first

key_path = ''

node['nodestack']['apps'].each_pair do |app_name, app_config| # each app loop

  user app_name do
    supports manage_home: true
    shell '/bin/bash'
    home "/home/#{app_name}"
  end

  directory "/home/#{app_name}/.ssh" do
    owner app_name
    group app_name
    mode 0700
    action :create
  end

  if app_config['ssh_auth']
    key_path = "/home/#{app_name}/.ssh/id_rsa"

    template 'ssh config with strict host check disabled' do
      source 'ssh_config.erb'
      path '/home/' + app_name + '/.ssh/config'
      mode 0700
      owner app_name
      group app_name
      variables(
        git_repo_domain: app_config['git_repo_domain']
      )
    end

    template 'deploy key' do
      source app_name + '_private_key'
      path key_path
      mode 0600
      owner app_name
      group app_name
      cookbook node['nodestack']['cookbook']
    end
  end

  application 'nodejs application' do
    path app_config['app_dir']
    owner app_name
    group app_name
    repository app_config['git_repo']
  end

  template 'config.js' do
    path app_config['app_dir'] + '/current/config.js'
    source 'config.js.erb'
    owner app_name
    group app_name
    mode '0644'
    variables(
      http_port: app_config['http_port'],
      mysql: mysql_node.respond_to?('deep_fetch') == true ? mysql_node : nil,
      mysql_user: app_name,
      mysql_password: app_config['mysql_app_user_password'],
      mysql_db_name: app_name,
      mongo: mongo_node.respond_to?('deep_fetch') == true ? mongo_node : nil,
      mongo_host: app_config['mongo_host']
    )
  end

  execute 'locally install npm packages from package.json' do
    cwd "#{app_config['app_dir']}/current"
    command 'npm install'
    environment ({'HOME' => "/home/#{ app_name }"})
    only_if {::File.exists?("#{ app_config['app_dir'] }/current/package.json") && app_config['npm']}
  end

  execute 'add forever to run app as daemon' do
    cwd "#{app_config['app_dir']}/current"
    command 'npm install forever -g'
    environment ({'HOME' => "/home/#{ app_name }"})
  end

  template app_name do
    path "/etc/init.d/#{app_name}"
    source 'nodejs.initd.erb'
    owner 'root'
    group 'root'
    mode '0755'
    variables(
      user: app_name,
      group: app_name,
      app_dir: app_config['app_dir'] + '/current',
      entry: app_config['entry_point']
    )
    only_if { platform_family?('rhel') }
  end

  template "#{app_name}.conf" do
    path "/etc/init/#{app_name}.conf"
    source 'nodejs.upstart.conf.erb'
    owner 'root'
    group 'root'
    mode '0644'
    variables(
      user: app_name,
      group: app_name,
      app_dir: app_config['app_dir'] + '/current',
      node_dir: node['nodejs']['dir'],
      entry: app_config['entry_point'],
      app_name: app_name
    )
    only_if { platform_family?('debian') }
  end

  service app_name do
    case node['platform']
    when 'ubuntu'
      provider Chef::Provider::Service::Upstart
    end
    action [:enable, :start]
  end

  add_iptables_rule('INPUT', "-m tcp -p tcp --dport #{app_config['port']} -j ACCEPT", 100, "Allow nodejs http traffic for #{app_name}")

end # end each app loop
