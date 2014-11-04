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

%w(chef-sugar nodejs nodejs::npm git build-essential nodestack::setcap
).each do |recipe|
  include_recipe recipe
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

  # Code deployment can be an optional step.
  # Be aware that npm dependencies will need to be handled by the code deployment strategy of your choosing
  # as well as starting/stopping and keeping Node.js applications running.
  if node['nodestack']['code_deployment'] == true

    # If we've enabled the git_branch_hack, we'll send 'HEAD' down to the git resource
    # and take the requested branch variable in 'git_rev_hack', which we'll use after the
    # "application" block to manually change to the target.
    if node['nodestack']['git_branch_hack'] == true
      git_rev_hack = app_config['git_rev']
      git_rev = 'HEAD'
    else
      git_rev = app_config['git_rev']
    end

    application 'nodejs application' do
      path app_config['app_dir']
      owner app_name
      group app_name
      enable_submodules app_config['enable_submodules']
      deploy_key encrypted_environment['ssh_deployment_key']
      repository app_config['git_repo']
      revision git_rev
      before_migrate do
        current_release = release_path
        template "#{current_release}/#{app_config['deployment']['before_symlink']}" do
          source app_config['deployment']['before_symlink_template']
          owner app_name
          group app_name
          mode '0744'
          cookbook node['nodestack']['cookbook']
          variables(
            app_config: app_config,
            templates_options: app_config['deployment']['template_options']
          )
          only_if { !app_config['deployment']['before_symlink'].nil? }
        end
      end
      before_symlink app_config['deployment']['before_symlink']
    end

    # Manually pull the latest release from the target branch
    if node['nodestack']['git_branch_hack'] == true
      execute "git fetch origin #{git_rev_hack} && git reset --hard FETCH_HEAD" do
        cwd "#{app_config['app_dir']}/current"
        user app_name
        group app_name
      end
    end

    # Run a git checkout against any linked sub repos.
    # Note that this is essentially the same as a "git submodule" (see application's enable_submodules).
    # However, there are times where having a customer set up git sub modules is a lot more complex
    # Than simply defining them in a hash here.
    # This hash takes the form of ['nodestack'][apps]['my_app']['dependant_repos'] = {
    #   "/models" => {
    #     "repository" => "", "revision" => ""
    #   }
    # }
    unless app_config['dependant_repos'].nil?
      app_config['dependant_repos'].each do |repo_path, repo|
        if repo.revision.nil?
          repo.revision = "HEAD"
        end
        git "#{app_deploy_dir}/#{repo_path}" do
          repository repo.repository
          revision repo.revision
          action :sync
        end
      end
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

# set this attribute so logstash can watch the logs
node.set['nodestack']['logstash']['logging_paths'] = logging_paths

# Add logrotate
include_recipe 'nodestack::logrotate'
