require "optionparser"
require "yaml"

module Dependaboat
  class Cli
    attr_reader :project_id, :owner, :repo, :project
    attr_accessor :logger

    def self.run
      new(*ARGV).run
    end

    def initialize(*argv)
      @dry_run = false # Default
      @logger = Dependaboat.logger
      options_parser.parse(argv)
    end

    def run
      @project = GHX::Project.new(@project_id)

      @alerts = GHX::Dependabot.get_alerts(owner: owner, repo: repo)

      logger.info("Found #{@alerts.size} Dependabot alerts")

      alerts_map = {"320" => {github_issue_number: "10656", github_project_item_id: "PVTI_lADOALH_aM4Ac-_zzgO9zko"}}

      @alerts.each do |alert|
        existing_issue = GHX::Issue.search(owner: owner, repo: repo, query: "[DB #{alert.number}]").any?
        if existing_issue
          logger.info "  Issue already exists for alert ##{alert.number}. Skipping."
          next
        end

        alert_number = alert.number
        alert_severity = alert.security_vulnerability.severity.capitalize
        alert_package_name = alert.security_vulnerability.package.name
        alert_package_ecosystem = alert.security_vulnerability.package.ecosystem
        alert_created_at = begin
          Date.parse(alert.created_at)
        rescue
          Date.today
        end

        remediation_deadline = alert_created_at + @config.dig("remediation_sla", alert_severity.downcase)

        template_variable_map = {
          "alert_number" => alert_number,
          "alert_severity" => alert_severity,
          "alert_package_name" => alert_package_name,
          "alert_package_ecosystem" => alert_package_ecosystem,
          "alert_created_at" => alert_created_at,
          "remediation_deadline" => remediation_deadline.to_time.strftime("%Y-%m-%d")
        }

        logger.info "Processing alert ##{alert_number} (#{alert_severity.upcase}) in #{alert_package_name} (#{alert_package_ecosystem}) created at #{alert_created_at}"

        if alerts_map[alert.number.to_s]
          logger.info "  Alert already has github issue: #{alerts_map[alert.number.to_s][:github_issue_number]}. Skipping."
          next
        else
          # TODO: Check to see if we already created an issue. Use the title field to try to find it. via [DB 123] etc.

          logger.info "  Creating new issue for this alert."

          title = "[DB #{alert.number}] " + process_templateable_string(@config.dig("github", "issue", "title"), template_variable_map)
          body = process_templateable_string(@config.dig("github", "issue", "body"), template_variable_map)
          labels_config = @config.dig("github", "issue", "labels") || []

          labels = labels_config.map do |template|
            process_templateable_string(template, template_variable_map)
          end

          issue = GHX::Issue.new(owner: @owner,
            repo: @repo,
            title: title,
            body: body,
            labels: labels,
            assignees: assignees_for_ecosystem(alert_package_ecosystem))

          if @dry_run
            logger.info "  Dry Run: Would have created issue:"
            logger.info issue.inspect
            next
          end

          issue.save

          logger.info "  Created Github Issue ##{issue.number} for alert ##{alert.number}"

          alerts_map[alert.number.to_s] = {github_issue_number: issue.number, github_project_item_id: nil}

          logger.info "  Waiting for GH automation to run and create the associated GH Project Item..."
          sleep 5

          logger.info "  Fetching Project Item..."
          project_item = project.find_item_by_issue_number(owner: owner, repo: repo, number: issue.number)

          logger.info "  Found project item #{project_item.id} for issue ##{issue.number}."

          logger.info "  Updating Project Item with additional data..."

          @config.dig("github", "project_item", "field_map").each do |field_map|
            field_name = field_map["field_name"]
            field_value = field_map["field_value"]

            logger.debug "    #{field_name} => #{field_value}"
            project_item.update(field_name => process_templateable_string(field_value, template_variable_map))
          end
        end
      end

      logger.info "Run complete."

      0
    end

    def load_config(path)
      config_file = File.expand_path(path)
      raise "Could not find config file" unless File.exist?(config_file)

      config = YAML.load_file(config_file)

      logger.info "Loaded config from #{config_file}"
      logger.info config

      @project_id = config.dig("github", "project_id")
      @owner = config.dig("github", "owner")
      @repo = config.dig("github", "repo")
      @assignees = config.dig("github", "issue", "assignees") || {}

      @config = config || {}
    end

    def options_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: dependaboat [options]"

        # Config File
        opts.on("-cCONFIG_FILE", "--config-file=CONFIG_FILE", "The path to the config file") do |config_file|
          load_config(config_file)
        end

        # Dry Run flag
        opts.on("-d", "--dry-run", "Run in dry-run mode") do
          @dry_run = true
        end

        opts.on("-h", "--help", "Prints this help") do
          puts opts
          exit
        end
      end
    end

    def assignees_for_ecosystem(ecosystem)
      assignees = Array(@assignees[ecosystem] || @assignees["other"])
      assignees << @assignees["all"]
      assignees.flatten.compact.uniq
    end

    def process_templateable_string(s, map)
      processed_s = s.dup
      map.each do |key, value|
        processed_s.gsub!("{{#{key}}}", value.to_s)
      end

      processed_s
    end
  end
end
