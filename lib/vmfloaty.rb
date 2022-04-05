# frozen_string_literal: true

require 'rubygems'
require 'commander'
require 'json'
require 'pp'
require 'uri'
require 'vmfloaty/auth'
require 'vmfloaty/pooler'
require 'vmfloaty/version'
require 'vmfloaty/conf'
require 'vmfloaty/utils'
require 'vmfloaty/service'
require 'vmfloaty/ssh'
require 'vmfloaty/logger'

class Vmfloaty
  include Commander::Methods

  def run # rubocop:disable Metrics/AbcSize
    program :version, Vmfloaty::VERSION
    program :description,
            "A CLI helper tool for Puppet's vmpooler to help you stay afloat.\n\nConfiguration may be placed in a ~/.vmfloaty.yml file."

    config = Conf.read_config

    command :get do |c|
      c.syntax = 'floaty get os_type0 os_type1=x ox_type2=y [options]'
      c.summary = 'Gets a vm or vms based on the os argument'
      c.description = 'A command to retrieve vms from a pooler service. Can either be a single vm, or multiple with the `=` syntax.'
      c.example 'Gets a few vms', 'floaty get centos=3 debian --user brian --url http://vmpooler.example.com'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--user STRING', String, 'User to authenticate with'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--token STRING', String, 'Token for pooler service'
      c.option '--priority STRING', 'Priority for supported backends(ABS) (High(1), Medium(2), Low(3))'
      c.option '--notoken', 'Makes a request without a token'
      c.option '--force', 'Forces vmfloaty to get requested vms'
      c.option '--json', 'Prints retrieved vms in JSON format'
      c.option '--ondemand', 'Requested vms are provisioned upon receival of the request, tracked by a request ID'
      c.option '--continue STRING', String, 'resume polling ABS for job_id, for use when the cli was interrupted'
      c.option '--loglevel STRING', String, 'the log level to use (debug, info, error)'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        FloatyLogger.setlevel = options.loglevel if options.loglevel
        service = Service.new(options, config)
        use_token = !options.notoken
        force = options.force

        if args.empty?
          FloatyLogger.error 'No operating systems provided to obtain. See `floaty get --help` for more information on how to get VMs.'
          exit 1
        end

        os_types = Utils.generate_os_hash(args)

        if os_types.empty?
          FloatyLogger.error 'No operating systems provided to obtain. See `floaty get --help` for more information on how to get VMs.'
          exit 1
        end

        max_pool_request = 5
        large_pool_requests = os_types.select { |_, v| v > max_pool_request }
        if !large_pool_requests.empty? && !force
          FloatyLogger.error "Requesting vms over #{max_pool_request} requires a --force flag."
          FloatyLogger.error 'Try again with `floaty get --force`'
          exit 1
        end

        response = service.retrieve(verbose, os_types, use_token, options.ondemand, options.continue)
        request_id = response['request_id'] if options.ondemand
        response = service.wait_for_request(verbose, request_id) if options.ondemand

        hosts = Utils.standardize_hostnames(response)

        if options.json || options.ondemand
          puts JSON.pretty_generate(hosts)
        else
          puts Utils.format_host_output(hosts)
        end
      end
    end

    command :list do |c|
      c.syntax = 'floaty list [options]'
      c.summary = 'Shows a list of available vms from the pooler or vms obtained with a token'
      c.description = 'List will either show all vm templates available in pooler service, or with the --active flag it will list vms obtained with a pooler service token.'
      c.example 'Filter the list on centos', 'floaty list centos --url http://vmpooler.example.com'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--active', 'Prints information about active vms for a given token'
      c.option '--json', 'Prints information as JSON'
      c.option '--hostnameonly', 'When listing active vms, prints only hostnames, one per line'
      c.option '--token STRING', String, 'Token for pooler service'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--user STRING', String, 'User to authenticate with'
      c.option '--loglevel STRING', String, 'the log level to use (debug, info, error)'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        FloatyLogger.setlevel = options.loglevel if options.loglevel

        service = Service.new(options, config)
        filter = args[0]

        if options.active
          # list active vms
          running_vms = if service.type == 'ABS'
                          # this is actually job_ids
                          service.list_active_job_ids(verbose, service.url, service.user)
                        else
                          service.list_active(verbose)
                        end
          host = URI.parse(service.url).host
          if running_vms.empty?
            if options.json
              puts {}.to_json
            else
              FloatyLogger.info "You have no running VMs on #{host}"
            end
          elsif options.json
            puts Utils.get_host_data(verbose, service, running_vms).to_json
          elsif options.hostnameonly
            Utils.get_host_data(verbose, service, running_vms).each do |hostname, host_data|
              Utils.print_fqdn_for_host(service, hostname, host_data)
            end
          else
            puts "Your VMs on #{host}:"
            Utils.pretty_print_hosts(verbose, service, running_vms)
          end
        else
          # list available vms from pooler
          os_list = service.list(verbose, filter)
          puts os_list
        end
      end
    end

    command :query do |c|
      c.syntax = 'floaty query hostname [options]'
      c.summary = 'Get information about a given vm'
      c.description = 'Given a hostname from the pooler service, vmfloaty with query the service to get various details about the vm. If using ABS, you can query a job_id'
      c.example 'Get information about a sample host', 'floaty query hostname --url http://vmpooler.example.com'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        service = Service.new(options, config)
        hostname = args[0]

        query_req = service.query(verbose, hostname)
        pp query_req
      end
    end

    command :modify do |c|
      c.syntax = 'floaty modify hostname [options]'
      c.summary = 'Modify a VM\'s tags, time to live, disk space, or reservation reason'
      c.description = 'This command makes modifications to the virtual machines state in the pooler service. You can either append tags to the vm, increase how long it stays active for, or increase the amount of disk space.'
      c.example 'Modifies myhost1 to have a TTL of 12 hours and adds a custom tag',
                'floaty modify myhost1 --lifetime 12 --url https://myurl --token mytokenstring --tags \'{"tag":"myvalue"}\''
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--token STRING', String, 'Token for pooler service'
      c.option '--lifetime INT', Integer, 'VM TTL (Integer, in hours) [vmpooler only]'
      c.option '--disk INT', Integer, 'Increases VM disk space (Integer, in gb) [vmpooler only]'
      c.option '--tags STRING', String, 'free-form VM tagging (json) [vmpooler only]'
      c.option '--reason STRING', String, 'VM reservation reason [nspooler only]'
      c.option '--all', 'Modifies all vms acquired by a token'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        service = Service.new(options, config)
        hostname = args[0]
        modify_all = options.all

        if hostname.nil? && !modify_all
          FloatyLogger.error 'ERROR: Provide a hostname or specify --all.'
          exit 1
        end
        running_vms =
          if modify_all
            service.list_active(verbose)
          else
            hostname.split(',')
          end

        tags = options.tags ? JSON.parse(options.tags) : nil
        modify_hash = {
          lifetime: options.lifetime,
          disk: options.disk,
          tags: tags,
          reason: options.reason
        }
        modify_hash.delete_if { |_, value| value.nil? }

        unless modify_hash.empty?
          ok = true
          modified_hash = {}
          running_vms.each do |vm|
            modified_hash[vm] = service.modify(verbose, vm, modify_hash)
          rescue ModifyError => e
            FloatyLogger.error e
            ok = false
          end
          if ok
            if modify_all
              puts "Successfully modified all #{running_vms.count} VMs."
            else
              puts "Successfully modified VM #{hostname}."
            end
            puts 'Use `floaty list --active` to see the results.'
          end
        end
      end
    end

    command :delete do |c|
      c.syntax = 'floaty delete hostname,hostname2 [options]'
      c.syntax += "\n    floaty delete job1,job2 [options] (only supported with ABS)"
      c.summary = 'Schedules the deletion of a host or hosts'
      c.description = 'Given a comma separated list of hostnames, or --all for all vms, vmfloaty makes a request to the pooler service to schedule the deletion of those vms. If you are using the ABS service, you can also pass in JobIDs here. Note that passing in a Job ID will delete *all* of the hosts in the job.' # rubocop:disable Layout/LineLength
      c.example 'Schedules the deletion of a host or hosts', 'floaty delete myhost1,myhost2 --url http://vmpooler.example.com'
      c.example 'Schedules the deletion of a JobID or JobIDs', 'floaty delete 1579300120799,1579300120800 --url http://abs.example.com'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--all', 'Deletes all vms acquired by a token'
      c.option '-f', 'Does not prompt user when deleting all vms'
      c.option '--json', 'Outputs hosts scheduled for deletion as JSON'
      c.option '--token STRING', String, 'Token for pooler service'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--user STRING', String, 'User to authenticate with'
      c.option '--loglevel STRING', String, 'the log level to use (debug, info, error)'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        FloatyLogger.setlevel = options.loglevel if options.loglevel

        service = Service.new(options, config)
        hostnames = args[0]
        delete_all = options.all
        force = options.f

        failures = []
        successes = []

        if delete_all
          running_vms = if service.type == 'ABS'
                          # this is actually job_ids
                          service.list_active_job_ids(verbose, service.url, service.user)
                        else
                          service.list_active(verbose)
                        end
          if running_vms.empty?
            if options.json
              puts {}.to_json
            else
              FloatyLogger.info 'You have no running VMs.'
            end
          else
            confirmed = true
            unless force
              Utils.pretty_print_hosts(verbose, service, running_vms, true)
              # Confirm deletion
              confirmed = agree('Delete all these VMs? [y/N]')
            end
            if confirmed
              response = service.delete(verbose, running_vms)
              response.each do |hostname, result|
                if result['ok']
                  successes << hostname
                else
                  failures << hostname
                end
              end
            end
          end
        elsif hostnames || args
          hostnames = hostnames.split(',')
          results = service.delete(verbose, hostnames)
          results.each do |hostname, result|
            if result['ok']
              successes << hostname
            else
              failures << hostname
            end
          end
        else
          FloatyLogger.info 'You did not provide any hosts to delete'
          exit 1
        end

        unless failures.empty?
          FloatyLogger.info 'Unable to delete the following VMs:'
          failures.each do |hostname|
            FloatyLogger.info "- #{hostname}"
          end
          FloatyLogger.info 'Check `floaty list --active`; Do you need to specify a different service?'
        end

        unless successes.empty?
          if options.json
            puts successes.to_json
          else
            puts 'Scheduled the following VMs for deletion:'
            output = ''
            successes.each do |hostname|
              output += "- #{hostname}\n"
            end
            puts output
          end
        end

        exit 1 unless failures.empty?
      end
    end

    command :snapshot do |c|
      c.syntax = 'floaty snapshot hostname [options]'
      c.summary = 'Takes a snapshot of a given vm'
      c.description = 'Will request a snapshot be taken of the given hostname in the pooler service. This command is known to take a while depending on how much load is on the pooler service.'
      c.example 'Takes a snapshot for a given host',
                'floaty snapshot myvm.example.com --url http://vmpooler.example.com --token a9znth9dn01t416hrguu56ze37t790bl'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--token STRING', String, 'Token for pooler service'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        service = Service.new(options, config)
        hostname = args[0]

        begin
          snapshot_req = service.snapshot(verbose, hostname)
        rescue TokenError, ModifyError => e
          FloatyLogger.error e
          exit 1
        end

        puts "Snapshot pending. Use `floaty query #{hostname}` to determine when snapshot is valid."
        pp snapshot_req
      end
    end

    command :revert do |c|
      c.syntax = 'floaty revert hostname snapshot [options]'
      c.summary = 'Reverts a vm to a specified snapshot'
      c.description = 'Given a snapshot SHA, vmfloaty will request a revert to the pooler service to go back to a previous snapshot.'
      c.example 'Reverts to a snapshot for a given host',
                'floaty revert myvm.example.com n4eb4kdtp7rwv4x158366vd9jhac8btq --url http://vmpooler.example.com --token a9znth9dn01t416hrguu56ze37t790bl'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--token STRING', String, 'Token for pooler service'
      c.option '--snapshot STRING', String, 'SHA of snapshot'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        service = Service.new(options, config)
        hostname = args[0]
        snapshot_sha = args[1] || options.snapshot

        if args[1] && options.snapshot
          FloatyLogger.info "Two snapshot arguments were given....using snapshot #{snapshot_sha}"
        end

        begin
          revert_req = service.revert(verbose, hostname, snapshot_sha)
        rescue TokenError, ModifyError => e
          FloatyLogger.error e
          exit 1
        end

        pp revert_req
      end
    end

    command :status do |c|
      c.syntax = 'floaty status [options]'
      c.summary = 'Prints the status of pools in the pooler service'
      c.description = 'Makes a request to the pooler service to request the information about vm pools and how many are ready to be used, what pools are empty, etc.'
      c.example 'Gets the current pooler service status', 'floaty status --url http://vmpooler.example.com'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--json', 'Prints status in JSON format'
      c.option '--loglevel STRING', String, 'the log level to use (debug, info, error)'
      c.action do |_, options|
        verbose = options.verbose || config['verbose']
        FloatyLogger.setlevel = options.loglevel if options.loglevel
        service = Service.new(options, config)
        if options.json
          pp service.status(verbose)
        else
          Utils.pretty_print_status(verbose, service)
        end
      end
    end

    command :summary do |c|
      c.syntax = 'floaty summary [options]'
      c.summary = 'Prints a summary of a pooler service'
      c.description = 'Gives a very detailed summary of information related to the pooler service.'
      c.example 'Gets the current day summary of the pooler service', 'floaty summary --url http://vmpooler.example.com'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.action do |_, options|
        verbose = options.verbose || config['verbose']
        service = Service.new(options, config)

        summary = service.summary(verbose)
        pp summary
        exit 0
      end
    end

    command :token do |c|
      c.syntax = 'floaty token <get delete status> [options]'
      c.summary = 'Retrieves or deletes a token or checks token status'
      c.description = 'This command is used to manage your pooler service token. Through the various options, you are able to get a new token, delete an existing token, and request a tokens status.'
      c.example 'Gets a token from the pooler', 'floaty token get'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--user STRING', String, 'User to authenticate with'
      c.option '--token STRING', String, 'Token for pooler service'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        service = Service.new(options, config)
        action = args.first

        begin
          case action
          when 'get'
            token = service.get_new_token(verbose)
            puts token
          when 'delete'
            result = service.delete_token(verbose, options.token)
            puts result
          when 'status'
            token_value = options.token
            token_value = args[1] if token_value.nil?
            status = service.token_status(verbose, token_value)
            puts status
          when nil
            FloatyLogger.error 'No action provided'
            exit 1
          else
            FloatyLogger.error "Unknown action: #{action}"
            exit 1
          end
        rescue TokenError => e
          FloatyLogger.error e
          exit 1
        end
        exit 0
      end
    end

    command :ssh do |c|
      c.syntax = 'floaty ssh os_type [options]'
      c.summary = 'Grabs a single vm and sshs into it'
      c.description = 'This command simply will grab a vm template that was requested, and then ssh the user into the machine all at once.'
      c.example 'SSHs into a centos vm', 'floaty ssh centos7 --url https://vmpooler.example.com'
      c.option '--verbose', 'Enables verbose output'
      c.option '--service STRING', String, 'Configured pooler service name'
      c.option '--url STRING', String, 'URL of pooler service'
      c.option '--user STRING', String, 'User to authenticate with'
      c.option '--token STRING', String, 'Token for pooler service'
      c.option '--notoken', 'Makes a request without a token'
      c.option '--priority STRING', 'Priority for supported backends(ABS) (High(1), Medium(2), Low(3))'
      c.option '--ondemand', 'Requested vms are provisioned upon receival of the request, tracked by a request ID'
      c.action do |args, options|
        verbose = options.verbose || config['verbose']
        service = Service.new(options, config)
        use_token = !options.notoken

        if args.empty?
          FloatyLogger.error 'No operating systems provided to obtain. See `floaty ssh --help` for more information on how to get VMs.'
          exit 1
        end

        host_os = args.first

        FloatyLogger.info "Can't ssh to multiple hosts; Using #{host_os} only..." if args.length > 1

        service.ssh(verbose, host_os, use_token, options.ondemand)
        exit 0
      end
    end

    command :completion do |c|
      c.syntax = 'floaty completion [options]'
      c.summary = 'Outputs path to completion script'
      c.description = Utils.strip_heredoc(<<-DESCRIPTION)
        Outputs path to a completion script for the specified shell (or 'bash' if not specified). This makes it easy to add the completion script to your profile:

          source $(floaty completion --shell bash)

        This subcommand will exit non-zero with an error message if no completion script is available for the requested shell.
      DESCRIPTION
      c.example 'Gets path to bash tab completion script', 'floaty completion --shell bash'
      c.option '--shell STRING', String, 'Shell to request completion script for'
      c.action do |_, options|
        shell = (options.shell || 'bash').downcase.strip
        completion_file = File.expand_path(File.join('..', '..', 'extras', 'completions', "floaty.#{shell}"), __FILE__)

        if File.exist?(completion_file)
          puts completion_file
          exit 0
        else
          FloatyLogger.error "Could not find completion file for '#{shell}': No such file #{completion_file}"
          exit 1
        end
      end
    end

    command :service do |c|
      c.syntax = 'floaty service <types examples>'
      c.summary = 'Display information about floaty services and their configuration'
      c.description = 'Display information about floaty services to aid in setting up a configuration file.'
      c.example 'Print a list of the valid service types', 'floaty service types'
      c.example 'Print a sample config file with multiple services', 'floaty service examples'
      c.example 'list vms from the service named "nspooler-prod"', 'floaty list --service nspooler-prod'
      c.action do |args, _options|
        action = args.first

        example_config = Utils.strip_heredoc(<<-CONFIG)
          # Sample ~/.vmfloaty.yml with just vmpooler
          user: 'jdoe'
          url: 'https://vmpooler.example.net'
          token: '456def789'

          # Sample ~/.vmfloaty.yml with multiple services
          # Note: when the --service is not specified on the command line,
          # the first service listed here is selected automatically
          user: 'jdoe'
          services:
            abs-prod:
              type: 'abs'
              url: 'https://abs.example.net/api/v2'
              token: '123abc456'
              vmpooler_fallback: 'vmpooler-prod'
            nspooler-prod:
              type: 'nspooler'
              url: 'https://nspooler.example.net'
              token:  '789ghi012'
            vmpooler-dev:
              type: 'vmpooler'
              url: 'https://vmpooler-dev.example.net'
              token: '987dsa654'
            vmpooler-prod:
              type: 'vmpooler'
              url: 'https://vmpooler.example.net'
              token: '456def789'

        CONFIG

        types_output = Utils.strip_heredoc(<<-TYPES)
          The values on the left below can be used in ~/.vmfloaty.yml as the value of type:

          abs:       Puppet's Always Be Scheduling
          nspooler:  Puppet's Non-standard Pooler, aka NSPooler
          vmpooler:  Puppet's VMPooler
        TYPES

        case action
        when 'examples'
          FloatyLogger.info example_config
        when 'types'
          FloatyLogger.info types_output
        when nil
          FloatyLogger.error 'No action provided'
          exit 1
        else
          FloatyLogger.error "Unknown action: #{action}"
          exit 1
        end
      end
    end

    run!
  end
end
