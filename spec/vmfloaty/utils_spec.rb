# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'commander/command'
require_relative '../../lib/vmfloaty/utils'

# allow changing config in service for tests
class Service
  attr_writer :config
end

describe Utils do
  describe '#standardize_hostnames' do
    before :each do
      @vmpooler_api_v1_response_body = '{
         "ok": true,
         "domain": "delivery.mycompany.net",
         "ubuntu-1610-x86_64": {
           "hostname": ["gdoy8q3nckuob0i", "ctnktsd0u11p9tm"]
         },
         "centos-7-x86_64": {
           "hostname": "dlgietfmgeegry2"
         }
       }'
       @vmpooler_api_v2_response_body = '{
         "ok": true,
         "ubuntu-1610-x86_64": {
           "hostname": ["gdoy8q3nckuob0i.delivery.mycompany.net", "ctnktsd0u11p9tm.delivery.mycompany.net"]
         },
         "centos-7-x86_64": {
           "hostname": "dlgietfmgeegry2.delivery.mycompany.net"
         }
       }'
      @nonstandard_response_body = '{
         "ok": true,
         "solaris-10-sparc": {
           "hostname": ["sol10-10.delivery.mycompany.net", "sol10-11.delivery.mycompany.net"]
         },
         "ubuntu-16.04-power8": {
           "hostname": "power8-ubuntu16.04-6.delivery.mycompany.net"
         }
       }'
    end

    it 'formats a result from vmpooler v1 api into a hash of os to hostnames' do
      result = Utils.standardize_hostnames(JSON.parse(@vmpooler_api_v1_response_body))
      expect(result).to eq('centos-7-x86_64' => ['dlgietfmgeegry2.delivery.mycompany.net'],
                           'ubuntu-1610-x86_64' => ['gdoy8q3nckuob0i.delivery.mycompany.net',
                                                    'ctnktsd0u11p9tm.delivery.mycompany.net'])
    end

    it 'formats a result from vmpooler v2 api into a hash of os to hostnames' do
      result = Utils.standardize_hostnames(JSON.parse(@vmpooler_api_v2_response_body))
      expect(result).to eq('centos-7-x86_64' => ['dlgietfmgeegry2.delivery.mycompany.net'],
                           'ubuntu-1610-x86_64' => ['gdoy8q3nckuob0i.delivery.mycompany.net',
                                                    'ctnktsd0u11p9tm.delivery.mycompany.net'])
    end

    it 'formats a result from the nonstandard pooler into a hash of os to hostnames' do
      result = Utils.standardize_hostnames(JSON.parse(@nonstandard_response_body))
      expect(result).to eq('solaris-10-sparc' => ['sol10-10.delivery.mycompany.net', 'sol10-11.delivery.mycompany.net'],
                           'ubuntu-16.04-power8' => ['power8-ubuntu16.04-6.delivery.mycompany.net'])
    end
  end

  describe '#format_host_output' do
    before :each do
      @vmpooler_results = {
        'centos-7-x86_64' => ['dlgietfmgeegry2.delivery.mycompany.net'],
        'ubuntu-1610-x86_64' => ['gdoy8q3nckuob0i.delivery.mycompany.net', 'ctnktsd0u11p9tm.delivery.mycompany.net']
      }
      @nonstandard_results = {
        'solaris-10-sparc' => ['sol10-10.delivery.mycompany.net', 'sol10-11.delivery.mycompany.net'],
        'ubuntu-16.04-power8' => ['power8-ubuntu16.04-6.delivery.mycompany.net']
      }
      @vmpooler_output = <<~OUT.chomp
        - dlgietfmgeegry2.delivery.mycompany.net (centos-7-x86_64)
        - gdoy8q3nckuob0i.delivery.mycompany.net (ubuntu-1610-x86_64)
        - ctnktsd0u11p9tm.delivery.mycompany.net (ubuntu-1610-x86_64)
      OUT
      @nonstandard_output = <<~OUT.chomp
        - sol10-10.delivery.mycompany.net (solaris-10-sparc)
        - sol10-11.delivery.mycompany.net (solaris-10-sparc)
        - power8-ubuntu16.04-6.delivery.mycompany.net (ubuntu-16.04-power8)
      OUT
    end
    it 'formats a hostname hash from vmpooler into a list that includes the os' do
      expect(Utils.format_host_output(@vmpooler_results)).to eq(@vmpooler_output)
    end

    it 'formats a hostname hash from the nonstandard pooler into a list that includes the os' do
      expect(Utils.format_host_output(@nonstandard_results)).to eq(@nonstandard_output)
    end
  end

  describe '#get_service_object' do
    it 'assumes vmpooler by default' do
      expect(Utils.get_service_object).to be Pooler
    end

    it 'uses abs when told explicitly' do
      expect(Utils.get_service_object('abs')).to be ABS
    end

    it 'uses nspooler when told explicitly' do
      expect(Utils.get_service_object('nspooler')).to be NonstandardPooler
    end

    it 'uses vmpooler when told explicitly' do
      expect(Utils.get_service_object('vmpooler')).to be Pooler
    end
  end

  describe '#get_service_config' do
    before :each do
      @default_config = {
        'url' => 'http://default.url',
        'user' => 'first.last.default',
        'token' => 'default-token'
      }
      @services_config = {
        'services' => {
          'vm' => {
            'url' => 'http://vmpooler.url',
            'user' => 'first.last.vmpooler',
            'token' => 'vmpooler-token'
          },
          'ns' => {
            'url' => 'http://nspooler.url',
            'user' => 'first.last.nspooler',
            'token' => 'nspooler-token'
          }
        }
      }
    end

    it "returns the first service configured under 'services' as the default if available" do
      config = @default_config.merge @services_config
      options = MockOptions.new({})
      expect(Utils.get_service_config(config, options)).to include @services_config['services']['vm']
    end

    it 'allows selection by configured service key' do
      config = @default_config.merge @services_config
      options = MockOptions.new(service: 'ns')
      expect(Utils.get_service_config(config, options)).to include @services_config['services']['ns']
    end

    it 'uses top-level service config values as defaults when configured service values are missing' do
      config = @default_config.merge @services_config
      config['services']['vm'].delete 'url'
      options = MockOptions.new(service: 'vm')
      expect(Utils.get_service_config(config, options)['url']).to eq 'http://default.url'
    end

    it "raises an error if passed a service name that hasn't been configured" do
      config = @default_config.merge @services_config
      options = MockOptions.new(service: 'none')
      expect { Utils.get_service_config(config, options) }.to raise_error ArgumentError
    end

    it 'prioritizes values passed as command line options over configuration options' do
      config = @default_config
      options = MockOptions.new(url: 'http://alternate.url', token: 'alternate-token')
      expected = config.merge('url' => 'http://alternate.url', 'token' => 'alternate-token')
      expect(Utils.get_service_config(config, options)).to include expected
    end
  end

  describe '#generate_os_hash' do
    before :each do
      @host_hash = { 'centos' => 1, 'debian' => 5, 'windows' => 1 }
    end

    it 'takes an array of os arguments and returns a formatted hash' do
      host_arg = ['centos', 'debian=5', 'windows=1']
      expect(Utils.generate_os_hash(host_arg)).to eq @host_hash
    end

    it 'returns an empty hash if there are no arguments provided' do
      host_arg = []
      expect(Utils.generate_os_hash(host_arg)).to be_empty
    end
  end

  describe '#print_fqdn_for_host' do
    let(:url) { 'http://pooler.example.com' }

    subject { Utils.print_fqdn_for_host(service, hostname, host_data) }

    describe 'with vmpooler host' do
      let(:service) { Service.new(MockOptions.new, 'url' => url) }
      let(:hostname) { 'mcpy42eqjxli9g2' }
      let(:domain) { 'delivery.mycompany.net' }
      let(:fqdn) { [hostname, domain].join('.') }

      let(:host_data) do
        {
          'template' => 'ubuntu-1604-x86_64',
          'lifetime' => 12,
          'running' => 9.66,
          'state' => 'running',
          'ip' => '127.0.0.1',
          'domain' => domain
        }
      end

      it 'outputs fqdn for host' do
        expect($stdout).to receive(:puts).with(fqdn)

        subject
      end
    end

    describe 'with nonstandard pooler host' do
      let(:service) { Service.new(MockOptions.new, 'url' => url, 'type' => 'ns') }
      let(:hostname) { 'sol11-9.delivery.mycompany.net' }
      let(:host_data) do
        {
          'fqdn' => hostname,
          'os_triple' => 'solaris-11-sparc',
          'reserved_by_user' => 'first.last',
          'reserved_for_reason' => '',
          'hours_left_on_reservation' => 35.89
        }
      end
      let(:fqdn) { hostname } # for nspooler these are the same

      it 'outputs fqdn for host' do
        expect($stdout).to receive(:puts).with(fqdn)

        subject
      end
    end

    describe 'with ABS host' do
      let(:service) { Service.new(MockOptions.new, 'url' => url, 'type' => 'abs') }
      let(:hostname) { '1597952189390' }
      let(:fqdn) { 'example-noun.delivery.puppetlabs.net' }
      let(:template) { 'ubuntu-1604-x86_64' }

      # This seems to be the miminal stub response from ABS for the current output
      let(:host_data) do
        {
          'state' => 'allocated',
          'allocated_resources' => [
            {
              'hostname' => fqdn,
              'type' => template,
              'enging' => 'vmpooler'
            }
          ],
          'request' => {
            'job' => {
              'id' => hostname
            }
          }
        }
      end

      it 'outputs fqdn for host' do
        expect($stdout).to receive(:puts).with(fqdn)

        subject
      end
    end
  end

  describe '#pretty_print_hosts' do
    let(:url) { 'http://pooler.example.com' }
    let(:verbose) { nil }
    let(:print_to_stderr) { false }

    before(:each) do
      allow(service).to receive(:query)
        .with(anything, hostname)
        .and_return(response_body)
    end

    subject { Utils.pretty_print_hosts(verbose, service, hostname, print_to_stderr) }

    describe 'with vmpooler service' do
      let(:service) { Service.new(MockOptions.new, 'url' => url) }

      let(:hostname) { 'mcpy42eqjxli9g2' }
      let(:domain) { 'delivery.mycompany.net' }
      let(:fqdn) { [hostname, domain].join('.') }

      let(:response_body) do
        {
          hostname => {
            'template' => 'ubuntu-1604-x86_64',
            'lifetime' => 12,
            'running' => 9.66,
            'state' => 'running',
            'ip' => '127.0.0.1',
            'domain' => domain
          }
        }
      end

      let(:default_output) { "- #{fqdn} (running, ubuntu-1604-x86_64, 9.66/12 hours)" }

      it 'prints output with host fqdn, template and duration info' do
        expect($stdout).to receive(:puts).with(default_output)

        subject
      end

      context 'when tags are supplied' do
        let(:hostname) { 'aiydvzpg23r415q' }
        let(:response_body) do
          {
            hostname => {
              'template' => 'redhat-7-x86_64',
              'lifetime' => 48,
              'running' => 7.67,
              'state' => 'running',
              'tags' => {
                'user' => 'bob',
                'role' => 'agent'
              },
              'ip' => '127.0.0.1',
              'domain' => domain
            }
          }
        end

        it 'prints output with host fqdn, template, duration info, and tags' do
          output = "- #{fqdn} (running, redhat-7-x86_64, 7.67/48 hours, user: bob, role: agent)"

          expect($stdout).to receive(:puts).with(output)

          subject
        end
      end

      context 'when print_to_stderr option is true' do
        let(:print_to_stderr) { true }

        it 'outputs to stderr instead of stdout' do
          expect($stderr).to receive(:puts).with(default_output)

          subject
        end
      end
    end

    describe 'with nonstandard pooler service' do
      let(:service) { Service.new(MockOptions.new, 'url' => url, 'type' => 'ns') }

      let(:hostname) { 'sol11-9.delivery.mycompany.net' }
      let(:response_body) do
        {
          hostname => {
            'fqdn' => hostname,
            'os_triple' => 'solaris-11-sparc',
            'reserved_by_user' => 'first.last',
            'reserved_for_reason' => '',
            'hours_left_on_reservation' => 35.89
          }
        }
      end

      let(:default_output) { "- #{hostname} (solaris-11-sparc, 35.89h remaining)" }

      it 'prints output with host, template, and time remaining' do
        expect($stdout).to receive(:puts).with(default_output)

        subject
      end

      context 'when reason is supplied' do
        let(:response_body) do
          {
            hostname => {
              'fqdn' => hostname,
              'os_triple' => 'solaris-11-sparc',
              'reserved_by_user' => 'first.last',
              'reserved_for_reason' => 'testing',
              'hours_left_on_reservation' => 35.89
            }
          }
        end

        it 'prints output with host, template, time remaining, and reason' do
          output = '- sol11-9.delivery.mycompany.net (solaris-11-sparc, 35.89h remaining, reason: testing)'

          expect($stdout).to receive(:puts).with(output)

          subject
        end
      end

      context 'when print_to_stderr option is true' do
        let(:print_to_stderr) { true }

        it 'outputs to stderr instead of stdout' do
          expect($stderr).to receive(:puts).with(default_output)

          subject
        end
      end
    end

    describe 'with ABS service' do
      let(:service) { Service.new(MockOptions.new, 'url' => url, 'type' => 'abs') }

      let(:hostname) { '1597952189390' }
      let(:fqdn) { 'example-noun.delivery.mycompany.net' }
      let(:fqdn_hostname) { 'example-noun' }
      let(:template) { 'ubuntu-1604-x86_64' }

      # This seems to be the miminal stub response from ABS for the current output
      let(:response_body) do
        {
          hostname => {
            'state' => 'allocated',
            'allocated_resources' => [
              {
                'hostname' => fqdn,
                'type' => template,
                'engine' => 'vmpooler'
              }
            ],
            'request' => {
              'job' => {
                'id' => hostname
              }
            }
          }
        }
      end

      # The vmpooler response contains metadata that is printed
      let(:domain) { 'delivery.mycompany.net' }
      let(:response_body_vmpooler) do
        {
          fqdn_hostname => {
            'template' => template,
            'lifetime' => 48,
            'running' => 7.67,
            'state' => 'running',
            'tags' => {
              'user' => 'bob',
              'role' => 'agent'
            },
            'ip' => '127.0.0.1',
            'domain' => domain
          }
        }
      end

      before(:each) do
        allow(Utils).to receive(:get_vmpooler_service_config).and_return({
                                                                           'url' => 'http://vmpooler.example.com',
                                                                           'token' => 'krypto-knight'
                                                                         })
        allow(service).to receive(:query)
          .with(anything, fqdn_hostname)
          .and_return(response_body_vmpooler)
      end

      let(:default_output_first_line) { "- [JobID:#{hostname}] <allocated>" }
      let(:default_output_second_line) { "  - #{fqdn} (#{template})" }

      it 'prints output with job id, host, and template' do
        expect($stdout).to receive(:puts).with(default_output_first_line)
        expect($stdout).to receive(:puts).with(default_output_second_line)

        subject
      end

      it 'prints more information when vmpooler_fallback is set output with job id, host, template, lifetime, user and role' do
        fallback = { 'vmpooler_fallback' => 'vmpooler' }
        service.config.merge! fallback
        default_output_second_line = "  - #{fqdn} (running, #{template}, 7.67/48 hours, user: bob, role: agent)"
        expect($stdout).to receive(:puts).with(default_output_first_line)
        expect($stdout).to receive(:puts).with(default_output_second_line)

        subject
      end

      it 'prints DESTROYED and hostname when destroyed' do
        fallback = { 'vmpooler_fallback' => 'vmpooler' }
        service.config.merge! fallback
        response_body_vmpooler[fqdn_hostname]['state'] = 'destroyed'
        default_output_second_line = "  - DESTROYED #{fqdn}"
        expect($stdout).to receive(:puts).with(default_output_first_line)
        expect($stdout).to receive(:puts).with(default_output_second_line)

        subject
      end

      context 'when print_to_stderr option is true' do
        let(:print_to_stderr) { true }

        it 'outputs to stderr instead of stdout' do
          expect($stderr).to receive(:puts).with(default_output_first_line)
          expect($stderr).to receive(:puts).with(default_output_second_line)

          subject
        end
      end
    end

    describe 'with ABS service returning vmpooler and nspooler resources' do
      let(:service) { Service.new(MockOptions.new, 'url' => url, 'type' => 'abs') }

      let(:hostname) { '1597952189390' }
      let(:fqdn) { 'this-noun.delivery.mycompany.net' }
      let(:fqdn_ns) { 'that-noun.delivery.mycompany.net' }
      let(:fqdn_hostname) { 'this-noun' }
      let(:fqdn_ns_hostname) { 'that-noun' }
      let(:template) { 'ubuntu-1604-x86_64' }
      let(:template_ns) { 'solaris-10-sparc' }

      # This seems to be the miminal stub response from ABS for the current output
      let(:response_body) do
        {
          hostname => {
            'state' => 'allocated',
            'allocated_resources' => [
              {
                'hostname' => fqdn,
                'type' => template,
                'engine' => 'vmpooler'
              },
              {
                'hostname' => fqdn_ns,
                'type' => template_ns,
                'engine' => 'nspooler'
              }
            ],
            'request' => {
              'job' => {
                'id' => hostname
              }
            }
          }
        }
      end

      # The vmpooler response contains metadata that is printed
      let(:domain) { 'delivery.mycompany.net' }
      let(:response_body_vmpooler) do
        {
          fqdn_hostname => {
            'template' => template,
            'lifetime' => 48,
            'running' => 7.67,
            'state' => 'running',
            'tags' => {
              'user' => 'bob',
              'role' => 'agent'
            },
            'ip' => '127.0.0.1',
            'domain' => domain
          }
        }
      end

      before(:each) do
        allow(Utils).to receive(:get_vmpooler_service_config).and_return({
                                                                           'url' => 'http://vmpooler.example.com',
                                                                           'token' => 'krypto-knight'
                                                                         })
        allow(service).to receive(:query)
          .with(anything, fqdn_hostname)
          .and_return(response_body_vmpooler)
      end

      let(:default_output_first_line) { "- [JobID:#{hostname}] <allocated>" }
      let(:default_output_second_line) { "  - #{fqdn} (#{template})" }
      let(:default_output_third_line) { "  - #{fqdn_ns} (#{template_ns})" }

      it 'prints output with job id, host, and template' do
        expect($stdout).to receive(:puts).with(default_output_first_line)
        expect($stdout).to receive(:puts).with(default_output_second_line)
        expect($stdout).to receive(:puts).with(default_output_third_line)

        subject
      end

      context 'when print_to_stderr option is true' do
        let(:print_to_stderr) { true }

        it 'outputs to stderr instead of stdout' do
          expect($stderr).to receive(:puts).with(default_output_first_line)
          expect($stderr).to receive(:puts).with(default_output_second_line)
          expect($stderr).to receive(:puts).with(default_output_third_line)

          subject
        end
      end
    end
  end

  describe '#get_vmpooler_service_config' do
    let(:Conf) { double }
    it 'returns an error if the vmpooler_fallback is not setup' do
      config = {
        'user' => 'foo',
        'services' => {
          'myabs' => {
            'url' => 'http://abs.com',
            'token' => 'krypto-night',
            'type' => 'abs'
          }
        }
      }
      allow(Conf).to receive(:read_config).and_return(config)
      expect do
        Utils.get_vmpooler_service_config(config['services']['myabs']['vmpooler_fallback'])
      end.to raise_error(ArgumentError)
    end
    it 'returns an error if the vmpooler_fallback is setup but cannot be found' do
      config = {
        'user' => 'foo',
        'services' => {
          'myabs' => {
            'url' => 'http://abs.com',
            'token' => 'krypto-night',
            'type' => 'abs',
            'vmpooler_fallback' => 'myvmpooler'
          }
        }
      }
      allow(Conf).to receive(:read_config).and_return(config)
      expect do
        Utils.get_vmpooler_service_config(config['services']['myabs']['vmpooler_fallback'])
      end.to raise_error(ArgumentError,
                         /myvmpooler/)
    end
    it 'returns the vmpooler_fallback config' do
      config = {
        'user' => 'foo',
        'services' => {
          'myabs' => {
            'url' => 'http://abs.com',
            'token' => 'krypto-night',
            'type' => 'abs',
            'vmpooler_fallback' => 'myvmpooler'
          },
          'myvmpooler' => {
            'url' => 'http://vmpooler.com',
            'token' => 'krypto-knight'
          }
        }
      }
      allow(Conf).to receive(:read_config).and_return(config)
      expect(Utils.get_vmpooler_service_config(config['services']['myabs']['vmpooler_fallback'])).to include({
                                                                                                               'url' => 'http://vmpooler.com',
                                                                                                               'token' => 'krypto-knight',
                                                                                                               'user' => 'foo',
                                                                                                               'type' => 'vmpooler'
                                                                                                             })
    end
  end
end
