require_relative '../../spec_helper'

describe 'using director with config server', type: :integration do
  with_reset_sandbox_before_each(config_server_enabled: true, user_authentication: 'uaa', uaa_encryption: 'asymmetric')
  let(:manifest_hash) do
    {
        'name' => 'simple',
        'director_uuid' => 'deadbeef',
        'releases' => [{'name' => 'bosh-release', 'version' => '0.1-dev'}],
        'update' => {
            'canaries' => 2,
            'canary_watch_time' => 4000,
            'max_in_flight' => 1,
            'update_watch_time' => 20
        },
        'instance_groups' => [{
            'name' => 'our_instance_group',
            'templates' => [{
                'name' => 'job_1_with_many_properties',
                'properties' => {
                    'gargamel' => {
                        'color' => 'pitch black'
                    }
                }
            }],
            'instances' => 1,
            'networks' => [{'name' => 'private'}],
            'properties' => {},
            'vm_type' => 'medium',
            'persistent_disk_type' => 'large',
            'azs' => ['z1'],
            'stemcell' => 'default'
        }],
        'stemcells' => [{'alias' => 'default', 'os' => 'toronto-os', 'version' => '1'}]
    }
  end

  let(:cloud_config) { Bosh::Spec::Deployments::cloud_config_with_placeholders }
  let(:client_env) { {'BOSH_CLIENT' => 'test', 'BOSH_CLIENT_SECRET' => 'secret', 'BOSH_CA_CERT' => "#{current_sandbox.certificate_path}"} }
  let(:config_server_helper) { Bosh::Spec::ConfigServerHelper.new(current_sandbox, logger)}

  def bosh_run_cck_with_resolution(num_errors, option=1, env={})
    env.each do |key, value|
      ENV[key] = value
    end

    output = ''
    bosh_runner.run_interactively('cck', deployment_name: 'simple', no_login: true, include_credentials: false) do |runner|
      (1..num_errors).each do
        expect(runner).to have_output 'Skip for now'

        runner.send_keys option.to_s
      end

      expect(runner).to have_output 'Continue?'
      runner.send_keys 'y'

      expect(runner).to have_output 'Succeeded'
      output = runner.output
    end
    output
  end

  context 'cloud config config contains placeholders' do

    context 'all placeholders are set in config server' do
      before do
        config_server_helper.put_value('/z1_cloud_properties', {'availability_zone' => 'us-east-1a'})
        config_server_helper.put_value('/z2_cloud_properties', {'availability_zone' => 'us-east-1b'})
        config_server_helper.put_value('/ephemeral_disk_placeholder', {'size' => '3000', 'type' => 'gp2'})
        config_server_helper.put_value('/disk_types_placeholder', [
            {
                'name' => 'small',
                'disk_size' => 3000,
                'cloud_properties' => {'type' => 'gp2'}
            }, {
                'name' => 'large',
                'disk_size' => 50_000,
                'cloud_properties' => {'type' => 'gp2'}
            }
        ])
        config_server_helper.put_value('/subnets_placeholder', [
            {
                'range' => '10.10.0.0/24',
                'gateway' => '10.10.0.1',
                'az' => 'z1',
                'static' => ['10.10.0.62'],
                'dns' => ['10.10.0.2'],
                'cloud_properties' => {'subnet' => 'subnet-f2744a86'}
            }, {
                'range' => '10.10.64.0/24',
                'gateway' => '10.10.64.1',
                'az' => 'z2',
                'static' => ['10.10.64.121', '10.10.64.122'],
                'dns' => ['10.10.0.2'],
                'cloud_properties' => {'subnet' => 'subnet-eb8bd3ad'}
            }
        ])
        config_server_helper.put_value('/workers_placeholder', 5)
      end

      it 'uses the interpolated values for a successful deploy' do
        deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, return_exit_code: true, include_credentials: false, env: client_env)
        
        create_vm_invocations = current_sandbox.cpi.invocations_for_method('create_vm')
        expect(create_vm_invocations.last.inputs['cloud_properties']).to eq({'availability_zone'=>'us-east-1a', 'ephemeral_disk'=>{'size'=>'3000','type'=>'gp2'}, 'instance_type'=>'m3.medium'})

        create_disk_invocations = current_sandbox.cpi.invocations_for_method('create_disk')
        expect(create_disk_invocations.last.inputs['size']).to eq(50_000)
        expect(create_disk_invocations.last.inputs['cloud_properties']).to eq({'type' => 'gp2'})
      end

      context 'after a successful deployment' do
        before do
          deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, return_exit_code: true, include_credentials: false, env: client_env)
        end

        context 'variable values were changed' do
          before do
            config_server_helper.put_value('/z1_cloud_properties', {'availability_zone' => 'us-mid-west'})
            config_server_helper.put_value('/disk_types_placeholder', [{'name' => 'large', 'disk_size' => 100_000, 'cloud_properties' => {'type' => 'gp1'}}])
          end

          context 'deployment has unresponsive agents' do
            before {
              current_sandbox.cpi.kill_agents
            }

            it 'should use old variable value during CCK - recreate VM' do
              pre_kill_invocations_size = current_sandbox.cpi.invocations.size

              recreate_vm = 3
              bosh_run_cck_with_resolution(1, recreate_vm, client_env)

              invocations = current_sandbox.cpi.invocations.drop(pre_kill_invocations_size)
              create_vm_invocation = invocations.select { |invocation| invocation.method_name == 'create_vm' }.last
              expect(create_vm_invocation.inputs['cloud_properties']).to eq({'availability_zone'=>'us-east-1a', 'ephemeral_disk'=>{'size'=>'3000','type'=>'gp2'}, 'instance_type'=>'m3.medium'})
            end
          end

          it 'should use old variable value during hard stop, start' do
            instance = director.instance('our_instance_group', '0', deployment_name: 'simple', include_credentials: false, env: client_env)

            bosh_runner.run("stop --hard #{instance.job_name}/#{instance.id}", deployment_name: 'simple', no_login: true, include_credentials: false, env: client_env)
            pre_start_invocations_size = current_sandbox.cpi.invocations.size

            bosh_runner.run("start #{instance.job_name}/#{instance.id}", deployment_name: 'simple', no_login: true, include_credentials: false, env: client_env)
            invocations = current_sandbox.cpi.invocations.drop(pre_start_invocations_size)

            create_vm_invocation = invocations.select { |invocation| invocation.method_name == 'create_vm' }.last
            expect(create_vm_invocation.inputs['cloud_properties']).to eq({'availability_zone'=>'us-east-1a', 'ephemeral_disk'=>{'size'=>'3000','type'=>'gp2'}, 'instance_type'=>'m3.medium'})
          end

          it 'should use the new variable values on redeploy' do
            pre_second_deploy_invocations_size = current_sandbox.cpi.invocations.size
            deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, return_exit_code: true, include_credentials: false, env: client_env)
            invocations = current_sandbox.cpi.invocations.drop(pre_second_deploy_invocations_size)

            create_vm_invocation = invocations.select { |invocation| invocation.method_name == 'create_vm' }.last
            expect(create_vm_invocation.inputs['cloud_properties']).to eq({'availability_zone'=>'us-mid-west', 'ephemeral_disk'=>{'size'=>'3000','type'=>'gp2'}, 'instance_type'=>'m3.medium'})

            create_disk_invocation = invocations.select { |invocation| invocation.method_name == 'create_disk' }.last
            expect(create_disk_invocation.inputs['cloud_properties']).to eq({'type' => 'gp1'})
            expect(create_disk_invocation.inputs['size']).to eq(100_000)
          end
        end

        context 'only leaf-cloud-property variable values were changed' do
          before do
            config_server_helper.put_value('/ephemeral_disk_placeholder',{'size' => '2000', 'type' => 'gp1'})
          end

          it 'should recreate the VM on redeploy' do
            old_instance = director.instance('our_instance_group', '0', deployment_name: 'simple', include_credentials: false, env: client_env)
            deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, return_exit_code: true, include_credentials: false, env: client_env)
            new_instance = director.instance('our_instance_group', '0', deployment_name: 'simple', include_credentials: false, env: client_env)

            expect(old_instance.vm_cid).to_not eq(new_instance.vm_cid)
          end

          it 'should use the new variable values on redeploy' do
            pre_second_deploy_invocations_size = current_sandbox.cpi.invocations.size
            deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, return_exit_code: true, include_credentials: false, env: client_env)
            invocations = current_sandbox.cpi.invocations.drop(pre_second_deploy_invocations_size)

            create_vm_invocation = invocations.select { |invocation| invocation.method_name == 'create_vm' }.last
            expect(create_vm_invocation.inputs['cloud_properties']).to eq({'availability_zone'=>'us-east-1a', 'ephemeral_disk'=>{'size'=>'2000','type'=>'gp1'}, 'instance_type'=>'m3.medium'})
          end
        end
      end
    end

    context 'all placeholders are NOT set in config server' do
      before do
        config_server_helper.put_value('/z1_cloud_properties', {'availability_zone' => 'us-east-1a'})
        config_server_helper.put_value('/z2_cloud_properties', {'availability_zone' => 'us-east-1b'})
        config_server_helper.put_value('/ephemeral_disk_placeholder', {'size' => '3000', 'type' => 'gp2'})
      end

      it 'errors on deploy' do
        expect {
          deploy_from_scratch(no_login: true, manifest_hash: manifest_hash, cloud_config_hash: cloud_config, return_exit_code: true, include_credentials: false, env: client_env)
        }.to raise_error
      end
    end
  end
end


