require "log4r"

require "vagrant/util/counter"

require File.expand_path("../base", __FILE__)

module VagrantPlugins
  module Chef
    module Provisioner
      # This class implements provisioning via chef-solo.
      class ChefSolo < Base
        extend Vagrant::Util::Counter
        include Vagrant::Util::Counter
        attr_reader :environments_folders
        attr_reader :cookbook_folders
        attr_reader :role_folders
        attr_reader :data_bags_folders

        def initialize(machine, config)
          super
          @logger = Log4r::Logger.new("vagrant::provisioners::chef_solo")
        end

        def configure(root_config)
          @cookbook_folders  = expanded_folders(@config.cookbooks_path, "cookbooks")
          @role_folders      = expanded_folders(@config.roles_path, "roles")
          @data_bags_folders = expanded_folders(@config.data_bags_path, "data_bags")
          @environments_folders = expanded_folders(@config.environments_path, "environments")

          share_folders(root_config, "csc", @cookbook_folders)
          share_folders(root_config, "csr", @role_folders)
          share_folders(root_config, "csdb", @data_bags_folders)
          share_folders(root_config, "cse", @environments_folders)
        end

        def provision
          # Verify that the proper shared folders exist.
          check = []
          [@cookbook_folders, @role_folders, @data_bags_folders, @environments_folders].each do |folders|
            folders.each do |type, local_path, remote_path|
              # We only care about checking folders that have a local path, meaning
              # they were shared from the local machine, rather than assumed to
              # exist on the VM.
              check << remote_path if local_path
            end
          end

          chown_provisioning_folder
          verify_shared_folders(check)
          verify_binary(chef_binary_path("chef-solo"))
          upload_encrypted_data_bag_secret
          setup_json
          setup_solo_config
          run_chef_solo
          delete_encrypted_data_bag_secret
        end

        # Converts paths to a list of properly expanded paths with types.
        def expanded_folders(paths, appended_folder=nil)
          # Convert the path to an array if it is a string or just a single
          # path element which contains the folder location (:host or :vm)
          paths = [paths] if paths.is_a?(String) || paths.first.is_a?(Symbol)

          results = []
          paths.each do |type, path|
            # Create the local/remote path based on whether this is a host
            # or VM path.
            local_path = nil
            remote_path = nil
            if type == :host
              # Get the expanded path that the host path points to
              local_path = File.expand_path(path, @machine.env.root_path)

              if File.exist?(local_path)
                # Path exists on the host, setup the remote path
                remote_path = "#{@config.provisioning_path}/chef-solo-#{get_and_update_counter(:cookbooks_path)}"
              else
                @machine.ui.warn(I18n.t("vagrant.provisioners.chef.cookbook_folder_not_found_warning",
                                       path: local_path.to_s))
                next
              end
            else
              # Path already exists on the virtual machine. Expand it
              # relative to where we're provisioning.
              remote_path = File.expand_path(path, @config.provisioning_path)

              # Remove drive letter if running on a windows host. This is a bit
              # of a hack but is the most portable way I can think of at the moment
              # to achieve this. Otherwise, Vagrant attempts to share at some crazy
              # path like /home/vagrant/c:/foo/bar
              remote_path = remote_path.gsub(/^[a-zA-Z]:/, "")
            end

            # If we have specified a folder name to append then append it
            remote_path += "/#{appended_folder}" if appended_folder

            # Append the result
            results << [type, local_path, remote_path]
          end

          results
        end

        # Shares the given folders with the given prefix. The folders should
        # be of the structure resulting from the `expanded_folders` function.
        def share_folders(root_config, prefix, folders)
          folders.each do |type, local_path, remote_path|
            if type == :host
              opts = {}
              opts[:id] = "v-#{prefix}-#{self.class.get_and_update_counter(:shared_folder)}"
              opts[:type] = @config.synced_folder_type if @config.synced_folder_type

              root_config.vm.synced_folder(local_path, remote_path, opts)
            end
          end
        end

        def setup_solo_config
          cookbooks_path = guest_paths(@cookbook_folders)
          roles_path = guest_paths(@role_folders)
          data_bags_path = guest_paths(@data_bags_folders).first
          environments_path = guest_paths(@environments_folders).first
          setup_config("provisioners/chef_solo/solo", "solo.rb", {
            :cookbooks_path => cookbooks_path,
            :recipe_url => @config.recipe_url,
            :roles_path => roles_path,
            :data_bags_path => data_bags_path,
            :environments_path => environments_path,
          })
        end

        def run_chef_solo
          if @config.run_list && @config.run_list.empty?
            @machine.ui.warn(I18n.t("vagrant.chef_run_list_empty"))
          end

          if @machine.guest.capability?(:wait_for_reboot)
            @machine.guest.capability(:wait_for_reboot)
          end

          command = build_command(:solo)

          @config.attempts.times do |attempt|
            if attempt == 0
              @machine.ui.info I18n.t("vagrant.provisioners.chef.running_solo")
            else
              @machine.ui.info I18n.t("vagrant.provisioners.chef.running_solo_again")
            end

            opts = { error_check: false, elevated: true }
            exit_status = @machine.communicate.sudo(command, opts) do |type, data|
              # Output the data with the proper color based on the stream.
              color = type == :stdout ? :green : :red

              data = data.chomp
              next if data.empty?

              @machine.ui.info(data, :color => color)
            end

            # There is no need to run Chef again if it converges
            return if exit_status == 0
          end

          # If we reached this point then Chef never converged! Error.
          raise ChefError, :no_convergence
        end

        def verify_shared_folders(folders)
          folders.each do |folder|
            @logger.debug("Checking for shared folder: #{folder}")
            if !@machine.communicate.test("test -d #{folder}", sudo: true)
              raise ChefError, :missing_shared_folders
            end
          end
        end

        protected

        # Extracts only the remote paths from a list of folders
        def guest_paths(folders)
          folders.map { |parts| parts[2] }
        end
      end
    end
  end
end
