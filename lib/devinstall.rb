require 'devinstall/version'
require 'devinstall/deep_symbolize'
require 'devinstall/utils'
require 'devinstall/settings'
require 'pp'

module Devinstall

  class Pkg

    include Utils

    def get_version
      case @config.type
        when :deb
          begin
            deb_changelog = File.expand_path "#{@config.local(:folder)}/#{@package}/debian/changelog" # This is the folder that should be checked
            unless File.exists? deb_changelog
              exit! <<-eos
                No 'debian/changelog' found in specified :local:folder (#{@config.local(:folder)})
                Please check your config file
              eos
            end
            @_package_version[:deb] = File.open(deb_changelog, 'r') { |f| f.gets.chomp.sub(/^.*\((.*)\).*$/, '\1') }
          rescue IOError => e
            exit! <<-eos
              IO Error while opening #{deb_changelog}
              Aborting \n #{e}
            eos
          end
      end
    end

    # @param [String] package
    def initialize(package, type, env)
      @config=Settings.instance #class variable,first thing!
      @config.pkg=package # very important!
      @type=type
      @env=env
      @package = package # currently implemented only for .deb packages (for .rpm later :D)
      @_package_version = {} # versions for types:
      @package_files = {}
      arch = @config.build(:arch)
      p_name = "#{@package}_#{get_version}"
      @package_files[:deb] = {deb: "#{p_name}_#{arch}.deb",
                              tgz: "#{p_name}.tar.gz",
                              dsc: "#{p_name}.dsc",
                              chg: "#{p_name}_amd64.changes"}
    end

    def upload
      scp = @config.base(:scp)
      repo = {}
      [:user, :host, :folder, :type].each do |k|
        repo[k] = @config.repos(k) # looks stupid
      end
      @package_files[type].each do |p, f|
        puts "Uploading #{f}\t\t[#{p}] to $#{repo[:host]}"
        command("#{scp} #{@config.local(:temp)}/#{f} #{repo[:user]}@#{repo[:host]}:#{repo[:folder]}")
      end
    rescue CommandError => e
      puts e.verbose_message
      exit! ''
    rescue KeyNotdefinederror => e
      puts e.message
      exit! ''
    end

    def build(pkg=@package, type=@type, env=@env)
      config = Settings.instance
      puts "Building package #{pkg} type #{type}"
      build=config.build(pkg:pkg, type:type, env:env)
      local=config.local(pkg:pkg, type:type, env:env)
      raise 'Invaild build configuration' unless build.valid?

      ssh = @config.base(:ssh)
      rsync = @config.base(:rsync)
      local_folder = File.expand_path local[:folder]
      local_temp   = File.expand_path local[:temp]

      build_command = build[:command].gsub('%f', build[:folder]).
          gsub('%t', build[:target]).
          gsub('%p', pkg.to_s).
          gsub('%T', type.to_s)

      upload_sources("#{local_folder}/", "#{build[:user]}@#{build[:host]}:#{build[:folder]}")
      command("#{ssh} #{build[:user]}@#{build[:host]} \"#{build_command}\"")
      @package_files[type].each do |p, t|
        puts "Receiving target #{p.to_s} for #{t.to_s}"
        command("#{rsync} -az #{build[:user]}@#{build[:host]}:#{build[:target]}/#{t} #{local_temp}")
      end
    rescue CommandError => e
      puts e.verbose_message
      exit! ''
    rescue KeyNotdefinederror => e
      puts e.message
      exit! ''
    end

    def install
      env = @config.env
      puts "Installing #{@package} in #{env} environment."
      local_temp = @config.local(:temp)
      sudo = @config.base(:sudo)
      scp = @config.base(:scp)
      type = @config.type
      install = {}
      [:user, :host, :folder].each do |k|
        install[k] = @config.install(k)
      end
      install[:host] = [install[:host]] unless Array === install[:host]
      case type
        when :deb
          install[:host].each do |host|
            command("#{scp} #{local_temp}/#{@package_files[type][:deb]} #{install[:user]}@#{host}:#{install[:folder]}")
            command("#{sudo} #{install[:user]}@#{host} /usr/bin/dpkg -i #{install[:folder]}/#{@package_files[type][:deb]}")
          end
        else
          exit! "unknown package type '#{type.to_s}'"
      end
    rescue CommandError => e
      puts e.verbose_message
      exit! ''
    rescue KeyNotdefinederror => e
      puts e.message
      exit! ''
    end

    def run_tests
      # check if we have the test section in the configuration file
      unless @config.respond_to? :tests
        puts 'No test section in the config file.'
        puts 'Skipping tests'
        return
      end
      # for tests we will use almost the same setup as for build
      test = {}
      [:user, :machine, :command, :folder].each do |k|
        test[k] = @config.tests(k)
      end
      ssh = @config.base(:ssh)
      # replace "variables" in commands
      test[:command] = test[:command].
          gsub('%f', test[:folder]).# %f is the folder where the sources are rsync-ed
          gsub('%t', @config.build(:target)).# %t is the folder where the build places the result
          gsub('%p', @package.to_s) # %p is the package name
      # take the sources from the local folder
      local_folder = File.expand_path @config.local(:folder)
      # upload them to the test machine
      upload_sources("#{local_folder}/", "#{test[:user]}@#{test[:machine]}:#{test[:folder]}")
      puts 'Running all tests'
      puts 'This will take some time and you have no output'
      command("#{ssh} #{test[:user]}@#{test[:machine]} \"#{test[:command]}\"")
    end

    def upload_sources (source, dest)
      rsync = @config.base(:rsync)
      command("#{rsync} -az #{source} #{dest}")
    end
  rescue CommandError => e
    puts e.verbose_message
    exit! ''
  rescue KeyNotdefinederror => e
    puts e.message
    exit! ''
  end

end

