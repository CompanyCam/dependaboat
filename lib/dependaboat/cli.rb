require "optionparser"
require "yaml"
require "time"

module Dependaboat
  class Cli
    attr_reader :project_id, :owner, :repo, :project, :config
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
      initialize_project
      fetch_and_process_alerts
      logger.info "Run complete."
      0
    end

    private

    def load_config(path)
      config_file = File.expand_path(path)
      raise "Could not find config file" unless File.exist?(config_file)

      @config = YAML.load_file(config_file)
      logger.info "Loaded config from #{config_file}"
      logger.info @config

      @project_id = config.dig("github", "project_id")
      @owner = config.dig("github", "owner")
      @repo = config.dig("github", "repo")
      @assignees = config.dig("github", "issue", "assignees") || {}
    end

    def initialize_project
      @project = GHX::Project.new(project_id)
    end

    def fetch_and_process_alerts
      @alerts = GHX::Dependabot.get_alerts(owner: owner, repo: repo)
      logger.info("Found #{@alerts.size} Dependabot alerts")

      @alerts.each do |alert|
        process_alert(alert)
        sleep 2 # Rate limiting
      end
    end

    def process_alert(alert)
      retry_count = 0
      begin
        return if issue_exists?(alert)
        alert_details = extract_alert_details(alert)
        create_github_issue(alert, alert_details)
      rescue GHX::RateLimitExceededError => e
        logger.error "Rate limit exceeded!"
        retry_count += 1
        if retry_count < 4
          logger.info "Slowing down and retrying..."
          sleep 15 * retry_count
          retry
        else
          logger.error "3 Retries failed. Moving on."
        end
      rescue => e
        logger.error "Error processing alert ##{alert.number}: #{e.message}"
      end
    end

    def issue_exists?(alert)
      existing_issue = GHX::Issue.search(owner: owner, repo: repo, query: issue_lookup_key(alert)).any?
      if existing_issue
        logger.info "  Issue already exists for alert ##{alert.number}. Skipping."
      end
      existing_issue
    end

    def extract_alert_details(alert)
      alert_number = alert.number
      alert_severity = alert.security_vulnerability.severity.capitalize
      alert_package_name = alert.security_vulnerability.package.name
      alert_package_ecosystem = alert.security_vulnerability.package.ecosystem
      alert_created_at = begin
        alert.created_at.to_date
      rescue
        Date.today
      end

      remediation_deadline = alert_created_at + config.dig("remediation_sla", alert_severity.downcase)

      {
        number: alert_number,
        severity: alert_severity,
        package_name: alert_package_name,
        package_ecosystem: alert_package_ecosystem,
        created_at: alert_created_at,
        remediation_deadline: remediation_deadline
      }
    end

    def create_github_issue(alert, details)
      template_variable_map = build_template_variable_map(details)

      logger.info "Processing alert ##{details[:number]} (#{details[:severity].upcase}) in #{details[:package_name]} (#{details[:package_ecosystem]}) created at #{details[:created_at]}"

      logger.info "  Creating new issue for this alert."

      title = build_issue_title(alert, template_variable_map)
      body = build_issue_body(template_variable_map)
      labels = build_issue_labels(template_variable_map)

      issue = build_github_issue(alert, title, body, labels)

      if dry_run?
        log_dry_run(issue)
        return
      end

      save_issue_and_update_project(alert, issue, template_variable_map)
    end

    def build_template_variable_map(details)
      {
        "alert_number" => details[:number],
        "alert_severity" => details[:severity],
        "alert_package_name" => details[:package_name],
        "alert_package_ecosystem" => details[:package_ecosystem],
        "alert_created_at" => details[:created_at],
        "remediation_deadline" => details[:remediation_deadline].strftime("%Y-%m-%d")
      }
    end

    def build_issue_title(alert, template_variable_map)
      issue_lookup_key(alert) + " " + process_templateable_string(config.dig("github", "issue", "title"), template_variable_map)
    end

    def build_issue_body(template_variable_map)
      process_templateable_string(config.dig("github", "issue", "body"), template_variable_map)
    end

    def build_issue_labels(template_variable_map)
      labels_config = config.dig("github", "issue", "labels") || []
      labels_config.map { |template| process_templateable_string(template, template_variable_map) }
    end

    def build_github_issue(alert, title, body, labels)
      GHX::Issue.new(
        owner: owner,
        repo: repo,
        title: title,
        body: body,
        labels: labels,
        assignees: assignees_for_ecosystem(alert.security_vulnerability.package.ecosystem)
      )
    end

    def assignees_for_ecosystem(ecosystem)
      assignees = Array(@assignees[ecosystem] || @assignees["other"])
      assignees << @assignees["all"]
      assignees.flatten.compact.uniq
    end

    def log_dry_run(issue)
      logger.info "  Dry Run: Would have created issue:"
      logger.info issue.inspect
    end

    def save_issue_and_update_project(alert, issue, template_variable_map)
      issue.save
      logger.info "  Created Github Issue ##{issue.number} for alert ##{alert.number}"

      logger.info "  Waiting for GH automation to run and create the associated GH Project Item..."
      sleep 5

      project_item = fetch_project_item(issue)
      update_project_item(project_item, template_variable_map)
    end

    def fetch_project_item(issue)
      project.find_item_by_issue_number(owner: owner, repo: repo, number: issue.number).tap do |project_item|
        logger.info "  Found project item #{project_item.id} for issue ##{issue.number}."
      end
    end

    def update_project_item(project_item, template_variable_map)
      logger.info "  Updating Project Item with additional data..."

      config.dig("github", "project_item", "field_map").each do |field_map|
        field_name = field_map["field_name"]
        field_value = field_map["field_value"]

        logger.debug "    #{field_name} => #{field_value}"
        project_item.update(field_name => process_templateable_string(field_value, template_variable_map))
      end
    end

    def issue_lookup_key(alert)
      "[#{@repo}/DB #{alert.number}]"
    end

    def options_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: dependaboat [options]"

        opts.on("-cCONFIG_FILE", "--config-file=CONFIG_FILE", "The path to the config file") do |config_file|
          load_config(config_file)
        end

        # Option to pass an access token to use for GitHub API requests
        opts.on("-tACCESS_TOKEN", "--gh-token=ACCESS_TOKEN", "The GitHub access token to use for API requests. Used for _all_ GH requests.") do |access_token|
          GHX.octokit_token = access_token
          GHX.graphql_token = access_token
          GHX.rest_client_token = access_token
        end

        # Option to pass an access token to use for Octokit API requests
        opts.on("--octokit-token=ACCESS_TOKEN", "The GitHub access token to use for Octokit API requests") do |access_token|
          GHX.octokit_token = access_token
        end

        # Option to pass an access token to use for GraphQL API requests
        opts.on("--graphql-token=ACCESS_TOKEN", "The GitHub access token to use for GraphQL API requests") do |access_token|
          GHX.graphql_token = access_token
        end

        # Option to pass an access token to use for REST client API requests
        opts.on("--rest-client-token=ACCESS_TOKEN", "The GitHub access token to use for REST client API requests") do |access_token|
          GHX.rest_client_token = access_token
        end

        # Dry run option
        opts.on("-d", "--dry-run", "Run in dry-run mode") do
          @dry_run = true
        end

        opts.on("-h", "--help", "Prints this help") do
          puts opts
          exit
        end
      end
    end

    def process_templateable_string(s, map)
      map.each_with_object(s.dup) { |(key, value), str|
        str.gsub!("{{#{key}}}", value.to_s)
      }
    end

    def dry_run?
      @dry_run
    end
  end
end
