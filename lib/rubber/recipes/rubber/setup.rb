namespace :rubber do

  desc <<-DESC
    Bootstraps instances by setting timezone, installing packages and gems
  DESC
  task :bootstrap do
    set_timezone
    link_bash
    upgrade_packages
    install_packages
    setup_volumes
    setup_gem_sources
    install_gems
    deploy.setup
  end

  desc <<-DESC
    Sets up aliases for instance hostnames based on contents of instance.yml.
    Generates /etc/hosts for local/remote machines and sets hostname on
    remote instances, and sets values in dynamic dns entries
  DESC
  required_task :setup_aliases do
    setup_local_aliases
    setup_remote_aliases
    setup_dns_aliases
  end

  desc <<-DESC
    Sets up local aliases for instance hostnames based on contents of instance.yml.
    Generates/etc/hosts for local machine
  DESC
  required_task :setup_local_aliases do
    hosts_file = '/etc/hosts'

    # Generate /etc/hosts contents for the local machine from instance config
    delim = "## rubber config #{rubber_env.domain} #{RUBBER_ENV}"
    local_hosts = delim + "\n"
    rubber_instances.each do |ic|
      # don't add unqualified hostname in local hosts file since user may be
      # managing multiple domains with same aliases
      hosts_data = [ic.full_name, ic.external_host, ic.internal_host].join(' ')
      local_hosts << ic.external_ip << ' ' << hosts_data << "\n"
    end
    local_hosts << delim << "\n"

    # Write out the hosts file for this machine, use sudo
    filtered = File.read(hosts_file).gsub(/^#{delim}.*^#{delim}\n?/m, '')
    logger.info "Writing out aliases into local machines #{hosts_file}, sudo access needed"
    Rubber::Util::sudo_open(hosts_file, 'w') do |f|
      f.write(filtered)
      f.write(local_hosts)
    end
  end

  desc <<-DESC
    Sets up aliases in dynamic dns provider for instance hostnames based on contents of instance.yml.
  DESC
  required_task :setup_dns_aliases do
    rubber_instances.each do |ic|
      update_dyndns(ic)
    end
  end

  desc <<-DESC
    Sets up aliases for instance hostnames based on contents of instance.yml.
    Generates /etc/hosts for remote machines and sets hostname on remote instances
  DESC
  task :setup_remote_aliases do
    hosts_file = '/etc/hosts'

    # Generate /etc/hosts contents for the remote instance from instance config
    delim = "## rubber config"
    delim = "#{delim} #{RUBBER_ENV}"
    remote_hosts = delim + "\n"
    rubber_instances.each do |ic|
      hosts_data = [ic.name, ic.full_name, ic.external_host, ic.internal_host].join(' ')
      remote_hosts << ic.internal_ip << ' ' << hosts_data << "\n"
    end
    remote_hosts << delim << "\n"
    if rubber_instances.size > 0
      # write out the hosts file for the remote instances
      # NOTE that we use "capture" to get the existing hosts
      # file, which only grabs the hosts file from the first host
      filtered = (capture "cat #{hosts_file}").gsub(/^#{delim}.*^#{delim}\n?/m, '')
      filtered = filtered + remote_hosts
      # Put the generated hosts back on remote instance
      put filtered, hosts_file

      # Setup hostname on instance so shell, etcs have nice display
      sudo "echo $CAPISTRANO:HOST$ > /etc/hostname && hostname $CAPISTRANO:HOST$"
    end

    # TODO
    # /etc/resolv.conf to add search domain
    # ~/.ssh/options to setup user/host/key aliases
  end

  desc <<-DESC
    Update to the newest versions of all packages/gems.
  DESC
  task :update do
    upgrade_packages
    update_gems
  end

  desc <<-DESC
    Upgrade to the newest versions of all Ubuntu packages.
  DESC
  task :upgrade_packages do
    package_helper(true)
  end

  desc <<-DESC
    Upgrade to the newest versions of all rubygems.
  DESC
  task :update_gems do
    gem_helper(true)
  end

  desc <<-DESC
    Install extra packages and gems.
  DESC
  task :install do
    install_packages
    install_gems
  end

  desc <<-DESC
    Install Ubuntu packages. Set 'packages' in rubber.yml to \
    be an array of strings.
  DESC
  task :install_packages do
    package_helper(false)
  end

  desc <<-DESC
    Install ruby gems. Set 'gems' in rubber.yml to \
    be an array of strings.
  DESC
  task :install_gems do
    gem_helper(false)
  end

  desc <<-DESC
    Install ruby gems defined in the rails environment.rb
  DESC
  after "deploy:symlink", "rubber:install_rails_gems" if Rubber::Util.is_rails?
  task :install_rails_gems do
    sudo "sh -c 'cd #{current_path} && RAILS_ENV=#{RUBBER_ENV} rake gems:install'"
  end

  desc <<-DESC
    Setup ruby gems sources. Set 'gemsources' in rubber.yml to \
    be an array of URI strings.
  DESC
  task :setup_gem_sources do
    if rubber_env.gemsources
      script = prepare_script 'gem_sources_helper', <<-'ENDSCRIPT'
        ruby - $@ <<-'EOF'

        sources = ARGV

        installed = []
        `gem sources -l`.grep(/^[^*]/) do |line|
            line = line.strip
            installed << line if line.size > 0
        end

        to_install = sources - installed
        to_remove = installed - sources

        if to_install.size > 0
          to_install.each do |source|
            system "gem sources -a #{source}"
            fail "Unable to add gem sources" if $?.exitstatus > 0
          end
        end
        if to_remove.size > 0
          to_remove.each do |source|
            system "gem sources -r #{source}"
            fail "Unable to remove gem sources" if $?.exitstatus > 0
          end
        end

        'EOF'
      ENDSCRIPT

      sudo "sh #{script} #{rubber_env.gemsources.join(' ')}"
    end
  end

  desc <<-DESC
    The ubuntu has /bin/sh linking to dash instead of bash, fix this
    You can override this task if you don't want this to happen
  DESC
  task :link_bash do
    sudo("ln -sf /bin/bash /bin/sh")
  end

  desc <<-DESC
    Set the timezone using the value of the variable named timezone. \
    Valid options for timezone can be determined by the contents of \
    /usr/share/zoneinfo, which can be seen here: \
    http://packages.ubuntu.com/cgi-bin/search_contents.pl?searchmode=filelist&word=tzdata&version=gutsy&arch=all&page=1&number=all \
    Remove 'usr/share/zoneinfo/' from the filename, and use the last \
    directory and file as the value. For example 'Africa/Abidjan' or \
    'posix/GMT' or 'Canada/Eastern'.
  DESC
  task :set_timezone do
    opts = get_host_options('timezone')
    sudo "bash -c 'echo $CAPISTRANO:VAR$ > /etc/timezone'", opts
    sudo "cp /usr/share/zoneinfo/$CAPISTRANO:VAR$ /etc/localtime", opts
    # restart syslog so that times match timezone
    sudo "/etc/init.d/sysklogd restart"
  end
  
  def update_dyndns(instance_item)
    env = rubber_cfg.environment.bind(instance_item.role_names, instance_item.name)
    if env.dns_provider
      provider = Rubber::Dns::get_provider(env.dns_provider, env)
      provider.update(instance_item.name, instance_item.external_ip)
    end
  end

  def destroy_dyndns(instance_item)
    env = rubber_cfg.environment.bind(instance_item.role_names, instance_item.name)
    if env.dns_provider
      provider = Rubber::Dns::get_provider(env.dns_provider, env)
      provider.destroy(instance_item.name)
    end
  end

  def package_helper(upgrade=false)
    opts = get_host_options('packages') do |pkg_list|
      expanded_pkg_list = []
      pkg_list.each do |pkg_spec|
        if pkg_spec.is_a?(Array)
          expanded_pkg_list << "#{pkg_spec[0]}=#{pkg_spec[1]}"
        else
          expanded_pkg_list << pkg_spec
        end
      end
      expanded_pkg_list.join(' ')
    end

    sudo "apt-get -q update"
    if upgrade
      sudo "/bin/sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get -q -y --force-yes dist-upgrade'"
    else
      sudo "/bin/sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get -q -y --force-yes install $CAPISTRANO:VAR$'", opts
    end
  end

  def custom_package(url_base, name, ver, install_test)
    rubber.run_script "install_#{name}", <<-ENDSCRIPT
      if [[ #{install_test} ]]; then
        arch=`uname -m`
        if [ "$arch" = "x86_64" ]; then
          src="#{url_base}/#{name}_#{ver}_amd64.deb"
        else
          src="#{url_base}/#{name}_#{ver}_i386.deb"
        fi
        src_file="${src##*/}"
        wget -qP /tmp ${src}
        dpkg -i /tmp/${src_file}
      fi
    ENDSCRIPT
  end

  def handle_gem_prompt(ch, data, str)
    ch[:data] ||= ""
    ch[:data] << data
    if data =~ />\s*$/
      logger.info data
      logger.info "The gem command is asking for a number:"
      choice = STDIN.gets
      ch.send_data(choice)
    else
      logger.info data
    end
  end

  # Helper for installing gems,allows one to respond to prompts
  def gem_helper(update=false)
    cmd = update ? "update" : "install"


    opts = get_host_options('gems') do |gem_list|
      expanded_gem_list = []
      gem_list.each do |gem_spec|
        if gem_spec.is_a?(Array)
          expanded_gem_list << "#{gem_spec[0]}:#{gem_spec[1]}"
        else
          expanded_gem_list << gem_spec
        end
      end
      expanded_gem_list.join(' ')
    end
    
    if opts.size > 0
      # Rubygems always installs even if the gem is already installed
      # When providing versions, rubygems fails unless versions are provided for all gems
      # This helper script works around these issues by installing gems only if they
      # aren't already installed, and separates versioned/unversioned into two separate
      # calls to rubygems
      script = prepare_script 'gem_helper', <<-'ENDSCRIPT'
        ruby - $@ <<-'EOF'

        gem_cmd = ARGV[0]
        gems = ARGV[1..-1]
        cmd = "gem #{gem_cmd} --no-rdoc --no-ri"

        to_install = {}
        to_install_ver = {}
        # gem list passed in, possibly with versions, as "gem1 gem2:1.2 gem3"
        gems.each do |gem_spec|
          parts = gem_spec.split(':')
          if parts[1]
            to_install_ver[parts[0]] = parts[1]
          else
            to_install[parts[0]] = true
          end
        end

        installed = {}
        `gem list --local`.each do |line|
            parts = line.scan(/(.*) \((.*)\)/).first
            next unless parts && parts.size == 2
            installed[parts[0]] = parts[1].split(",")
        end

        to_install.delete_if {|g, v| installed.has_key?(g) } if gem_cmd == 'install'
        to_install_ver.delete_if {|g, v| installed.has_key?(g) && installed[g].include?(v) } 

        # when versions are provided for a gem, rubygems fails unless versions
        # are provided for all gems so we need to do the two groups separately
        if to_install.size > 0
          gem_list = to_install.keys.join(' ')
          system "#{cmd} #{gem_list}"
          fail "Unable to install gems" if $?.exitstatus > 0
        end
        if to_install_ver.size > 0
          gem_list = to_install_ver.collect {|g, v| "#{g} -v #{v}"}.join(' ')
          system "#{cmd} #{gem_list}"
          fail "Unable to install versioned gems" if $?.exitstatus > 0
        end

        'EOF'
      ENDSCRIPT

      sudo "sh #{script} #{cmd} $CAPISTRANO:VAR$", opts do |ch, str, data|
        handle_gem_prompt(ch, data, str)
      end
    end
  end

end