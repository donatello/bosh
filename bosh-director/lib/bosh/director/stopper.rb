module Bosh::Director
  class Stopper
    def initialize(instance_plan, target_state, skip_drain, config, logger)
      @instance_plan = instance_plan
      @instance = instance_plan.instance
      @target_state = target_state
      @skip_drain = skip_drain
      @config = config
      @logger = logger
    end

    def stop
      return if @instance.model.compilation || @instance.model.vm.nil?

      if @skip_drain
        @logger.info("Skipping drain for '#{@instance}'")
      else
        perform_drain
      end

      agent_client.stop
    end

    private

    def agent_client
      @agent_client ||= AgentClient.with_vm(@instance.model.vm)
    end

    def perform_drain
      drain_type = shutting_down? ? 'shutdown' : 'update'

      # Apply spec might change after shutdown drain (unlike update drain)
      # because instance's VM could be reconfigured.
      # Drain script can still capture intent from non-final apply spec.
      drain_time = agent_client.drain(drain_type, @instance.apply_spec)

      if drain_time > 0
        sleep(drain_time)
      else
        wait_for_dynamic_drain(drain_time)
      end
    end

    def shutting_down?
      @target_state == 'stopped' ||
        @target_state == 'detached' ||
        @instance_plan.resource_pool_changed? ||
        @instance_plan.needs_recreate? ||
        @instance.persistent_disk_changed? ||
        @instance_plan.networks_changed?
    end

    def wait_for_dynamic_drain(initial_drain_time)
      drain_time = initial_drain_time

      loop do
        # This could go on forever if drain script is broken, canceling the task is a way out.
        @config.task_checkpoint

        wait_time = drain_time.abs
        if wait_time > 0
          @logger.info("`#{@instance}' is draining: checking back in #{wait_time}s")
          sleep(wait_time)
        end

        # Positive number always means last drain call:
        break if drain_time >= 0

        # We used to ignore exceptions from drain status for compatibility
        # with older agents but it doesn't need to happen anymore, as
        # realistically speaking, all agents have already been updated
        # to support drain status mechanism and swallowing real errors
        # would be bad here, as it could mask potential problems.
        drain_time = agent_client.drain('status')
      end
    end
  end
end
