module Pod
  # Stores the information relative to the target used to cluster the targets
  # of the single Pods. The client targets will then depend on this one.
  #
  class AggregateTarget < Target
    # Product types where the product's frameworks must be embedded in a host target
    #
    EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES = [:app_extension, :framework, :static_library, :messages_extension, :watch_extension, :xpc_service].freeze

    # @return [TargetDefinition] the target definition of the Podfile that
    #         generated this target.
    #
    attr_reader :target_definition

    # @return [Pathname] the folder where the client is stored used for
    #         computing the relative paths. If integrating it should be the
    #         folder where the user project is stored, otherwise it should
    #         be the installation root.
    #
    attr_reader :client_root

    # @return [Xcodeproj::Project] the user project that this target will
    #         integrate as identified by the analyzer.
    #
    attr_reader :user_project

    # @return [Array<String>] the list of the UUIDs of the user targets that
    #         will be integrated by this target as identified by the analyzer.
    #
    # @note   The target instances are not stored to prevent editing different
    #         instances.
    #
    attr_reader :user_target_uuids

    # @return [Hash<String, Xcodeproj::Config>] Map from configuration name to
    #         configuration file for the target
    #
    # @note   The configurations are generated by the {TargetInstaller} and
    #         used by {UserProjectIntegrator} to check for any overridden
    #         values.
    #
    attr_reader :xcconfigs

    # @return [Array<PodTarget>] The dependencies for this target.
    #
    attr_accessor :pod_targets

    # @return [Array<AggregateTarget>] The aggregate targets whose pods this
    #         target must be able to import, but will not directly link against.
    #
    attr_reader :search_paths_aggregate_targets

    # Initialize a new instance
    #
    # @param [Sandbox] sandbox @see Target#sandbox
    # @param [Boolean] host_requires_frameworks @see Target#host_requires_frameworks
    # @param [Hash{String=>Symbol}] user_build_configurations @see Target#user_build_configurations
    # @param [Array<String>] archs @see Target#archs
    # @param [Platform] platform @see #Target#platform
    # @param [TargetDefinition] target_definition @see #target_definition
    # @param [Pathname] client_root @see #client_root
    # @param [Xcodeproj::Project] user_project @see #user_project
    # @param [Array<String>] user_target_uuids @see #user_target_uuids
    # @param [Array<PodTarget>] pod_targets_for_build_configuration @see #pod_targets_for_build_configuration
    #
    def initialize(sandbox, host_requires_frameworks, user_build_configurations, archs, platform, target_definition,
                   client_root, user_project, user_target_uuids, pod_targets_for_build_configuration)
      super(sandbox, host_requires_frameworks, user_build_configurations, archs, platform)
      raise "Can't initialize an AggregateTarget without a TargetDefinition!" if target_definition.nil?
      raise "Can't initialize an AggregateTarget with an abstract TargetDefinition!" if target_definition.abstract?
      @target_definition = target_definition
      @client_root = client_root
      @user_project = user_project
      @user_target_uuids = user_target_uuids
      @pod_targets_for_build_configuration = pod_targets_for_build_configuration
      @pod_targets = pod_targets_for_build_configuration.values.flatten.uniq
      @search_paths_aggregate_targets = []
      @xcconfigs = {}
    end

    def build_settings(configuration_name = nil)
      if configuration_name
        @build_settings[configuration_name] ||
          raise(ArgumentError, "#{self} does not contain a build setting for the #{configuration_name.inspect} configuration, only #{@build_settings.keys.inspect}")
      else
        @build_settings.each_value.first ||
          raise(ArgumentError, "#{self} does not contain any build settings")
      end
    end

    # @return [Boolean] True if the user_target refers to a
    #         library (framework, static or dynamic lib).
    #
    def library?
      # Without a user_project, we can't say for sure
      # that this is a library
      return false if user_project.nil?
      symbol_types = user_targets.map(&:symbol_type).uniq
      raise ArgumentError, "Expected single kind of user_target for #{name}. Found #{symbol_types.join(', ')}." unless symbol_types.count == 1
      [:framework, :dynamic_library, :static_library].include? symbol_types.first
    end

    # @return [Boolean] True if the user_target's pods are
    #         for an extension and must be embedded in a host,
    #         target, otherwise false.
    #
    def requires_host_target?
      # If we don't have a user_project, then we can't
      # glean any info about how this target is going to
      # be integrated, so return false since we can't know
      # for sure that this target refers to an extension
      # target that would require a host target
      return false if user_project.nil?
      symbol_types = user_targets.map(&:symbol_type).uniq
      raise ArgumentError, "Expected single kind of user_target for #{name}. Found #{symbol_types.join(', ')}." unless symbol_types.count == 1
      EMBED_FRAMEWORKS_IN_HOST_TARGET_TYPES.include?(symbol_types[0])
    end

    # @return [String] the label for the target.
    #
    def label
      target_definition.label.to_s
    end

    # @return [Podfile] The podfile which declares the dependency
    #
    def podfile
      target_definition.podfile
    end

    # @return [Pathname] the path of the user project that this target will
    #         integrate as identified by the analyzer.
    #
    def user_project_path
      user_project.path if user_project
    end

    # List all user targets that will be integrated by this #target.
    #
    # @return [Array<PBXNativeTarget>]
    #
    def user_targets
      return [] unless user_project
      user_target_uuids.map do |uuid|
        native_target = user_project.objects_by_uuid[uuid]
        unless native_target
          raise Informative, '[Bug] Unable to find the target with ' \
            "the `#{uuid}` UUID for the `#{self}` integration library"
        end
        native_target
      end
    end

    # @param  [String] build_configuration The build configuration for which the
    #         the pod targets should be returned.
    #
    # @return [Array<PodTarget>] the pod targets for the given build
    #         configuration.
    #
    def pod_targets_for_build_configuration(build_configuration)
      @pod_targets_for_build_configuration[build_configuration] || []
    end

    # @return [Array<Specification>] The specifications used by this aggregate target.
    #
    def specs
      pod_targets.flat_map(&:specs)
    end

    # @return [Hash{Symbol => Array<Specification>}] The pod targets for each
    #         build configuration.
    #
    def specs_by_build_configuration
      result = {}
      user_build_configurations.keys.each do |build_configuration|
        result[build_configuration] = pod_targets_for_build_configuration(build_configuration).
          flat_map(&:specs)
      end
      result
    end

    # @return [Array<Specification::Consumer>] The consumers of the Pod.
    #
    def spec_consumers
      specs.map { |spec| spec.consumer(platform) }
    end

    # @return [Boolean] Whether the target uses Swift code
    #
    def uses_swift?
      pod_targets.any?(&:uses_swift?)
    end

    # @return [Hash{String => Array<Hash{Symbol => [String]}>}] The vendored dynamic artifacts and framework target
    #         input and output paths grouped by config
    #
    def framework_paths_by_config
      @framework_paths_by_config ||= begin
        framework_paths_by_config = {}
        user_build_configurations.keys.each do |config|
          relevant_pod_targets = pod_targets_for_build_configuration(config)
          framework_paths_by_config[config] = relevant_pod_targets.flat_map { |pt| pt.framework_paths(false) }
        end
        framework_paths_by_config
      end
    end

    # @return [Hash{String => Array<String>}] Uniqued Resources grouped by config
    #
    def resource_paths_by_config
      @resource_paths_by_config ||= begin
        relevant_pod_targets = pod_targets.reject do |pod_target|
          pod_target.should_build? && pod_target.requires_frameworks? && !pod_target.static_framework?
        end
        user_build_configurations.keys.each_with_object({}) do |config, resources_by_config|
          resources_by_config[config] = (relevant_pod_targets & pod_targets_for_build_configuration(config)).flat_map do |pod_target|
            (pod_target.resource_paths(false) + [bridge_support_file].compact).uniq
          end
        end
      end
    end

    # @return [Pathname] the path of the bridge support file relative to the
    #         sandbox or `nil` if bridge support is disabled.
    #
    def bridge_support_file
      bridge_support_path.relative_path_from(sandbox.root) if podfile.generate_bridge_support?
    end

    #-------------------------------------------------------------------------#

    # @!group Support files

    # @return [Pathname] The absolute path of acknowledgements file.
    #
    # @note   The acknowledgements generators add the extension according to
    #         the file type.
    #
    def acknowledgements_basepath
      support_files_dir + "#{label}-acknowledgements"
    end

    # @return [Pathname] The absolute path of the copy resources script.
    #
    def copy_resources_script_path
      support_files_dir + "#{label}-resources.sh"
    end

    # @return [Pathname] The absolute path of the embed frameworks script.
    #
    def embed_frameworks_script_path
      support_files_dir + "#{label}-frameworks.sh"
    end

    # @return [String] The output file path fo the check manifest lock script.
    #
    def check_manifest_lock_script_output_file_path
      "$(DERIVED_FILE_DIR)/#{label}-checkManifestLockResult.txt"
    end

    # @return [String] The xcconfig path of the root from the `$(SRCROOT)`
    #         variable of the user's project.
    #
    def relative_pods_root
      "${SRCROOT}/#{sandbox.root.relative_path_from(client_root)}"
    end

    # @return [String] The path of the Podfile directory relative to the
    #         root of the user project.
    #
    def podfile_dir_relative_path
      podfile_path = target_definition.podfile.defined_in_file
      return "${SRCROOT}/#{podfile_path.relative_path_from(client_root).dirname}" unless podfile_path.nil?
      # Fallback to the standard path if the Podfile is not represented by a file.
      '${PODS_ROOT}/..'
    end

    # @param  [String] config_name The build configuration name to get the xcconfig for
    # @return [String] The path of the xcconfig file relative to the root of
    #         the user project.
    #
    def xcconfig_relative_path(config_name)
      relative_to_srcroot(xcconfig_path(config_name)).to_s
    end

    # @return [String] The path of the copy resources script relative to the
    #         root of the user project.
    #
    def copy_resources_script_relative_path
      "${SRCROOT}/#{relative_to_srcroot(copy_resources_script_path)}"
    end

    # @return [String] The path of the embed frameworks relative to the
    #         root of the user project.
    #
    def embed_frameworks_script_relative_path
      "${SRCROOT}/#{relative_to_srcroot(embed_frameworks_script_path)}"
    end

    private

    # @!group Private Helpers
    #-------------------------------------------------------------------------#

    # Computes the relative path of a sandboxed file from the `$(SRCROOT)`
    # variable of the user's project.
    #
    # @param  [Pathname] path
    #         A relative path from the root of the sandbox.
    #
    # @return [String] The computed path.
    #
    def relative_to_srcroot(path)
      path.relative_path_from(client_root).to_s
    end

    def create_build_settings
      settings = {}

      user_build_configurations.each_key do |configuration_name|
        settings[configuration_name] = BuildSettings::AggregateTargetSettings.new(self, configuration_name)
      end

      settings
    end
  end
end
