# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/measures/measure_writing_guide/

require 'csv'
require 'openstudio'

# start the measure
class BuildExistingModel < OpenStudio::Ruleset::ModelUserScript

  # human readable name
  def name
    return "Build Existing Model"
  end

  # human readable description
  def description
    return "Builds the OpenStudio Model for an existing building."
  end

  # human readable description of modeling approach
  def modeler_description
    return "Builds the OpenStudio Model using the sampling csv file, which contains the specified parameters for each existing building. Based on the supplied building number, those parameters are used to run the OpenStudio measures with appropriate arguments and build up the OpenStudio model."
  end
  
  def option_num
    return 1
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Ruleset::OSArgumentVector.new

    building_id = OpenStudio::Ruleset::OSArgument.makeIntegerArgument("building_id", true)
    building_id.setDisplayName("Building ID")
    building_id.setDescription("The building number (between 1 and the number of samples).")
    args << building_id
    
    workflow_json = OpenStudio::Ruleset::OSArgument.makeStringArgument("workflow_json", false)
    workflow_json.setDisplayName("Workflow JSON")
    workflow_json.setDescription("The name of the JSON file (in the resources dir) that dictates the order in which measures are to be run. If not provided, the order specified in resources/options_lookup.tsv will be used.")
    args << workflow_json
    
    number_of_buildings_represented = OpenStudio::Ruleset::OSArgument.makeIntegerArgument("number_of_buildings_represented", false)
    number_of_buildings_represented.setDisplayName("Number of Buildings Represented")
    number_of_buildings_represented.setDescription("The total number of buildings represented by the existing building models.")
    args << number_of_buildings_represented
    
    # Option Downselect Logic argument
    downselect_logic = OpenStudio::Ruleset::OSArgument.makeStringArgument("downselect_logic", false)
    downselect_logic.setDisplayName("Downselect Logic")
    downselect_logic.setDefaultValue("Location EPW|USA_TX_Houston-Bush.Intercontinental.AP.722430_TMY3.epw || Vintage|<1950")
    downselect_logic.setDescription("Logic that specifies if Downselect #{option_num} will apply based on the existing building's options. Specify one or more parameter|option as found in resources\\options_lookup.tsv. When multiple are included, they must be separated by '||' for OR and '&&' for AND, and using parentheses as appropriate. Prefix an option with '!' for not.")
    args << downselect_logic
    
    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end
    
    building_id = runner.getIntegerArgumentValue("building_id",user_arguments)
    workflow_json = runner.getOptionalStringArgumentValue("workflow_json",user_arguments)
    number_of_buildings_represented = runner.getOptionalIntegerArgumentValue("number_of_buildings_represented",user_arguments)
    
    # Get file/dir paths
    resources_dir = File.absolute_path(File.join(File.dirname(__FILE__), "..", "..", "lib", "resources")) # Should have been uploaded per 'Additional Analysis Files' in PAT
    characteristics_dir = File.absolute_path(File.join(File.dirname(__FILE__), "..", "..", "lib", "housing_characteristics")) # Should have been uploaded per 'Additional Analysis Files' in PAT
    buildstock_file = File.join(resources_dir, "buildstock.rb")
    measures_dir = File.join(resources_dir, "measures")
    lookup_file = File.join(resources_dir, "options_lookup.tsv")
    buildstock_csv = File.absolute_path(File.join(characteristics_dir, "buildstock.csv"))
    if workflow_json.is_initialized
        workflow_json = File.join(resources_dir, workflow_json.get)
    else
        workflow_json = nil
    end
    downselect_logic = runner.getOptionalStringArgumentValue("downselect_logic",user_arguments)
    
    # Load buildstock_file
    require File.join(File.dirname(buildstock_file), File.basename(buildstock_file, File.extname(buildstock_file)))

    # Run sampling script; if sampling has been done, use that instead.
    if not File.exists? buildstock_csv

      runner.registerInfo("Generating buildstock.csv sampling results.")
    
      require 'json'
      # analysis = JSON.parse(File.absolute_path(File.join(File.dirname(__FILE__), "..", "..", "analysis.json")))
      # runner.registerInfo(analysis)
      num_datapoints = 100 # TODO: NUMDATAPOINTS=`awk -F\"maximum\": 'NF>=2 {print $2}' analysis.json | sed 's/,//g' | head -n1 | xargs` # Yes, this is gross.

      require_relative File.join(resources_dir, 'run_sampling')
      r = RunSampling.new
      r.run("NA", num_datapoints, "buildstock.csv")

      FileUtils.cp File.join(resources_dir, "buildstock.csv"), buildstock_csv
      runner.registerInfo("NUMDATAPOINTS is #{num_datapoints}.")

    else

      runner.registerInfo("Sampling results buildstock.csv already exists on the worker CPU.")

    end

    # Check file/dir paths exist
    check_dir_exists(measures_dir, runner)
    check_file_exists(lookup_file, runner)
    check_file_exists(buildstock_csv, runner)

    # Retrieve all data associated with sample number
    bldg_data = get_data_for_sample(buildstock_csv, building_id, runner)

    # Retrieve order of parameters to run
    parameters_ordered = get_parameters_ordered_from_options_lookup_tsv(resources_dir, characteristics_dir)

    # Obtain measures and arguments to be called
    measures = {}
    parameters_ordered.each do |parameter_name|
        # Get measure name and arguments associated with the option
        option_name = bldg_data[parameter_name]
        print_option_assignment(parameter_name, option_name, runner)
        register_value(runner, parameter_name, option_name)

        options_measure_args = get_measure_args_from_option_names(lookup_file, [option_name], parameter_name, runner)
        options_measure_args[option_name].each do |measure_subdir, args_hash|
            update_args_hash(measures, measure_subdir, args_hash, add_new=false)
        end

    end
    
    # Do the downselecting
    if downselect_logic.is_initialized
   
      downselect_logic = downselect_logic.get
      downselect_logic = downselect_logic.strip
      downselected = evaluate_logic(downselect_logic, runner, past_results=false)

      if downselected.nil?
        return false
      end
      
      unless downselected
        # Not in downselection; don't run existing home simulation
        runner.haltWorkflow('Invalid')
        return false
      end

    end
    
    if not apply_measures(measures_dir, measures, runner, model, workflow_json, "measures.osw", true)
      return false
    end
    
    # Determine weight
    if not number_of_buildings_represented.nil?
        total_samples = nil
        runner.analysis[:analysis][:problem][:workflow].each do |wf|
            next if wf[:name] != 'build_existing_model'
            wf[:variables].each do |v|
                next if v[:argument][:name] != 'building_id'
                total_samples = v[:maximum].to_f
            end
        end
        if total_samples.nil?
            runner.registerError("Could not retrieve value for number_of_buildings_represented.")
            return false
        end
        weight = number_of_buildings_represented.get / total_samples
        register_value(runner, "weight", weight.to_s)
    end
    
    if not workflow_json.nil?
        register_value(runner, "workflow_json", workflow_json)
    end

    return true

  end
  
  def get_data_for_sample(buildstock_csv, building_id, runner)
    CSV.foreach(buildstock_csv, headers:true) do |sample|
        next if sample["Building"].to_i != building_id
        return sample
    end
    # If we got this far, couldn't find the sample #
    msg = "Could not find row for #{building_id.to_s} in #{File.basename(buildstock_csv).to_s}."
    runner.registerError(msg)
    fail msg
  end

end

# register the measure to be used by the application
BuildExistingModel.new.registerWithApplication
