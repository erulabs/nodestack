# Encoding: utf-8
#
# Cookbook Name:: nodestack
# Recipe:: application_nodejs
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

require 'json'

case node['platform_family']
when 'rhel', 'fedora'
  include_recipe 'yum'
else
  node.set['apt']['compile_time_update'] = true
  include_recipe 'apt'
end

if node['nodestack']['install_node'] == true
  %w(nodejs nodejs::npm).each do |recipe|
    include_recipe recipe
  end
end

%w(chef-sugar git build-essential).each do |recipe|
  include_recipe recipe
end

if node.deep_fetch('nodestack', 'bind_low_ports')
  include_recipe 'nodestack::setcap'
end

logging_paths = []
node['nodestack']['apps'].each do |app| # each app loop
  app_name = app[0]
  app_config = node['nodestack']['apps'][app_name]

  # Cleanup multiple strings referring to
  # "#{app_config['app_dir']/current/foo"
  app_deploy_dir = "#{app_config['app_dir']}/current"

  encrypted_databag = Chef::EncryptedDataBagItem.load("#{app_name}_databag", 'config')
  encrypted_environment = encrypted_databag[node.chef_environment]

  include_recipe 'nodestack::_user'

  app_config['env'].each_pair do |variable, value|
    magic_shell_environment variable do
      value value
      notifies :restart, "service[#{app_name}]", :delayed
    end
  end

  # Setup Node environment
  %w(logs pids).each do |dir|
    directory "#{app_config['app_dir']}/#{dir}" do
      owner app_name
      group app_name
      recursive true
      mode 0755
      action :create
    end
  end

  # With NodeJS, web-sockets are common. Web sockets are just like Unix sockets - they are a file!
  # Therefore, many customers ask us to up the open file limit (ulimit -n) per application
  # This is not only good to allow more than 1024 connections (common default ulimit -n),
  # But can also be used to limit the number of connections the application can accept.
  user_ulimit app_name do
    filehandle_limit app_config['open_files']
    only_if { !app_config['open_files'].nil? }
  end

  # Code deployment can be an optional step.
  # Be aware that npm dependencies will need to be handled by the code deployment strategy of your choosing
  # as well as starting/stopping and keeping Node.js applications running.
  if node['nodestack']['code_deployment'] == true

    application 'nodejs application' do
      path app_config['app_dir']
      owner app_name
      group app_name
      enable_submodules app_config['enable_submodules']
      deploy_key encrypted_environment['ssh_deployment_key']
      repository app_config['git_repo']
      revision app_config['git_rev']
      before_migrate do
        template "#{release_path}/#{app_config['deployment']['before_symlink']}" do
          source app_config['deployment']['before_symlink_template']
          owner app_name
          group app_name
          mode '0744'
          cookbook node['nodestack']['cookbook']
          variables(
            app_name: app_name,
            app_config: app_config,
            templates_options: app_config['deployment']['template_options'],
            release_path: release_path
          )
          only_if { !app_config['deployment']['before_symlink'].nil? }
        end
      end
      before_symlink app_config['deployment']['before_symlink']
    end

    template 'config.js' do
      path "#{app_deploy_dir}/config.js"
      source 'config.js.erb'
      owner app_name
      group app_name
      mode '0644'
      variables(
        config_js: encrypted_environment['config']
      )
      only_if { app_config['config_file'] }
    end

    # Install npm and dependencies
    nodejs_npm app_name do
      path app_deploy_dir
      json true
      user app_name
      group app_name
      options app_config['npm_options']
      retries 5
      retry_delay 30
      only_if { ::File.exist?("#{ app_deploy_dir }/package.json") && app_config['npm'] }
    end
  end # ends app deployment

  add_iptables_rule('INPUT', "-m tcp -p tcp --dport #{app_config['env']['PORT']} -j ACCEPT",
                    100, "Allow nodejs traffic for #{app_name}") if app_config['env']['PORT']

  logging_paths.push("#{app_config['app_dir']}/logs/*")

  # set this attribute so logstash can watch the logs
  node.set['nodestack']['logstash']['logging_paths'] = logging_paths

  # Add logrotate
  include_recipe 'nodestack::logrotate'

  case app_config['deployment']['strategy']
  when nil
    Chef::Log.info("You have not set the attribute for ['deployment']['strategy'], forever will be used as a default")
    include_recipe 'nodestack::forever'
  when 'forever'
    include_recipe 'nodestack::forever'
  else
    Chef::Log.warn("#{app_config['deployment']['strategy']} isn't a deployment strategy this cookbook is familiar with. This is not necessarily an error.")
  end
end # end each app loop
