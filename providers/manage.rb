#
# Cookbook Name:: users
# Provider:: manage
#
# Copyright 2011, Eric G. Wolfe
# Copyright 2009-2015, Chef Software, Inc.
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

use_inline_resources

def whyrun_supported?
  true
end

def chef_solo_search_installed?
  klass = ::Search.const_get('Helper')
  return klass.is_a?(Class)
rescue NameError
  return false
end

action :remove do
  if Chef::Config[:solo] && !chef_solo_search_installed?
    Chef::Log.warn('This recipe uses search. Chef Solo does not support search unless you install the chef-solo-search cookbook.')
  else
    
    search(new_resource.data_bag, "groups:#{new_resource.search_group} AND action:remove") do |rm_user|
      user rm_user['username'] ||= rm_user['id'] do
        action :remove
      end
    end
    
    search(new_resource.data_bag, "groups:#{new_resource.search_group} AND NOT (action:remove OR environments:all OR environments:#{node.chef_environment})") do |rm_user|
      user rm_user['username'] ||= rm_user['id'] do
        action :lock
        ignore_failure true
      end
    end if new_resource.require_environments
    
  end
end

action :create do
  security_group = []
  all_keys = []

  if Chef::Config[:solo] && !chef_solo_search_installed?
    Chef::Log.warn('This recipe uses search. Chef Solo does not support search unless you install the chef-solo-search cookbook.')
  else
    # Set home_basedir based on platform_family
    case node['platform_family']
      when 'mac_os_x'
        home_basedir = '/Users'
      when 'debian', 'rhel', 'fedora', 'arch', 'suse', 'freebsd', 'openbsd', 'slackware', 'gentoo'
        home_basedir = '/home'
    end

    search_query = "groups:#{new_resource.search_group}"    
    search_query << " AND (environments:all OR environments:#{node.chef_environment})" if new_resource.require_environments 
    search_query << " AND NOT action:remove"
    search(new_resource.data_bag, search_query) do |u|
      u['username'] ||= u['id']
      security_group << u['username']

      if node['apache'] && node['apache']['allowed_openids']
        Array(u['openid']).compact.each do |oid|
          node.default['apache']['allowed_openids'] << oid unless node['apache']['allowed_openids'].include?(oid)
        end
      end

      # Set home to location in data bag,
      # or a reasonable default ($home_basedir/$user)
      home_dir = u['home'] || "#{home_basedir}/#{u['username']}"

      # The user block will fail if the group does not yet exist.
      # See the -g option limitations in man 8 useradd for an explanation.
      # This should correct that without breaking functionality.
      group u['username'] do
        gid u['gid']
        only_if { u['gid'] && u['gid'].is_a?(Numeric) }
      end

      # Create user object.
      # Do NOT try to manage null home directories.
      user u['username'] do
        uid u['uid']
        gid u['gid'] if u['gid']
        shell u['shell']
        comment u['comment']
        password u['password'] if u['password']
        if home_dir == '/dev/null'
          supports manage_home: false
        else
          supports manage_home: true
        end
        home home_dir
        action u['action'] if u['action']
      end

      if manage_home_files?(home_dir, u['username'])
        Chef::Log.debug("Managing home files for #{u['username']}")

        directory "#{home_dir}/.ssh" do
          owner u['username']
          group u['gid'] || u['username']
          mode '0700'
        end

        template "#{home_dir}/.ssh/authorized_keys" do
          source 'authorized_keys.erb'
          cookbook new_resource.cookbook
          owner u['username']
          group u['gid'] || u['username']
          mode '0600'
          variables ssh_keys: u['ssh_keys']
          only_if { u['ssh_keys'] }
        end

        all_keys += u['ssh_keys'] if u['ssh_key']

        if u['ssh_private_key']
          key_type = u['ssh_private_key'].include?('BEGIN RSA PRIVATE KEY') ? 'rsa' : 'dsa'
          template "#{home_dir}/.ssh/id_#{key_type}" do
            source 'private_key.erb'
            cookbook new_resource.cookbook
            owner u['id']
            group u['gid'] || u['id']
            mode '0400'
            variables private_key: u['ssh_private_key']
          end
        end

        if u['ssh_public_key']
          key_type = u['ssh_public_key'].include?('ssh-rsa') ? 'rsa' : 'dsa'
          template "#{home_dir}/.ssh/id_#{key_type}.pub" do
            source 'public_key.pub.erb'
            cookbook new_resource.cookbook
            owner u['id']
            group u['gid'] || u['id']
            mode '0400'
            variables public_key: u['ssh_public_key']
          end
        end
      else
        Chef::Log.debug("Not managing home files for #{u['username']}")
      end
    end

    if node['tags'].include?(new_resource.git_tag)
      group new_resource.git_group do
      end

      user new_resource.git_user do
        gid new_resource.git_group
        shell new_resource.git_shell
        comment 'Git user with all certificates'
        home "#{home_basedir}/#{new_resource.git_user}"
      end

      directory "#{home_dir}/.ssh" do
        owner new_resource.git_user
        group new_resource.git_group
        mode '0700'
      end

      template "#{home_basedir}/#{new_resource.git_user}/.ssh/authorized_keys" do
        source 'authorized_keys.erb'
        cookbook new_resource.cookbook
        owner new_resource.git_user
        group new_resource.git_group
        mode '0600'
        variables ssh_keys: all_keys
      end
    end

  end

  group new_resource.group_name do
    gid new_resource.group_id if new_resource.group_id
    members security_group
  end
end

private

def manage_home_files?(home_dir, _user)
  # Don't manage home dir if it's NFS mount
  # and manage_nfs_home_dirs is disabled
  if home_dir == '/dev/null'
    false
  elsif fs_remote?(home_dir)
    new_resource.manage_nfs_home_dirs ? true : false
  else
    true
  end
end
