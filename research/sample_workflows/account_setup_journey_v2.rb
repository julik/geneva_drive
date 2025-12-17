# Journey to handle initial account setup after Google OAuth connection
#
# This journey orchestrates all the necessary steps to set up a new account:
# 1. Sync categories from templates (ensures basic categories are available)
# 2. Sync Gmail labels
# 3. Fetch important emails for fact extraction (perform_now)
# 4. Extract facts from emails (perform_later)
# 5. Fetch training emails for writing style
# 6. Generate writing style from training emails
# 7. Fetch historical emails
# 8. Generate email templates
# 9. Mark setup complete
#
# @example Start the journey after OAuth connection
#   AccountSetupJourneyV2.create!(hero: account)
#
class AccountSetupJourneyV2 < StepperMotor::Journey
  alias_method :account, :hero
  delegate :source_connected_account, to: :account
  cancel_if { account.nil? || !source_connected_account || !source_connected_account.scopes_valid? }

  # TODO: Remove this queue override once async memory issue is fixed
  set_step_job_options queue: :puppeteer

  # Create a journey if no existing journey exists for the account
  # @param account [Account] The account to set up
  # @return [AccountSetupJourneyV2, nil] The journey instance or nil if one already exists
  def self.create_if_none_exists(account:)
    # Check if any journey already exists for this account
    return nil if AccountSetupJourneyV2.for_hero(account).any?
    # Create V2 journey if none exists
    create!(hero: account)
  end

  # Automatically set Current.account for token usage tracking before each step
  # This ensures that any services using ClaudeClient will have proper token tracking
  def before_step_starts(step_name)
    Current.account = account
    setup_step_progress(step_name)
  end

  # Step 1: Sync categories from templates
  # This ensures basic categories (Newsletter, Timely, etc.) are available for classification
  step :sync_categories do
    skip! if account.categories.any?

    current_step_task.update_to(percent: 25, message: "Setting up categories...")

    result = TemplateSyncServiceV2.call(account)
    logger.info "Synced #{result.inserted_categories} categories for account: #{account.id}"

    current_step_task.update_to(percent: 100, message: "Categories synced successfully")
  ensure
    current_step_task.done!
  end

  # Step 2: Sync Gmail labels
  step :sync_labels do
    # Enable the account again if it was disabled when the user start onboarding
    if source_connected_account.disabled?
      source_connected_account.update!(disabled: false)
    end

    cancel! unless source_connected_account.can_access_gmail?
    skip! if source_connected_account.labels_synced?

    current_step_task.update_to(percent: 25, message: "Connecting to Gmail...")

    gmail_label_service = GmailLabelService.new(source_connected_account)
    created_labels = gmail_label_service.create_labels

    current_step_task.update_to(percent: 75, message: "Creating labels...")

    logger.info "Created #{created_labels.count} labels for account: #{source_connected_account.owner.email}"
    gmail_label_service.verify_labels_created!

    current_step_task.update_to(percent: 100, message: "Labels synced successfully")
  ensure
    current_step_task.done!
  end

  # Step 2: Fetch important emails for fact extraction
  step :fetch_important_emails do
    # Broadcast initial progress
    broadcast_progress(0, "Starting email analysis...")

    result = FetchImportantEmailsService.new(account) do |progress, message|
      # Forward progress updates from the service
      broadcast_progress(progress, message)
    end.run

    cancel! unless result
  end

  # Step 3: Extract facts from emails
  step :extract_facts do
    skip! if account.email_processing_states.none?

    # Use V2 service directly for better progress control and immediate execution
    service = FactExtractorServiceV2.new(account, task_progress: current_step_task)
    result = service.extract_and_persist

    cancel! unless result
  ensure
    current_step_task.done!
  end

  # Step 4: Fetch training emails for writing style
  step :fetch_training_emails do
    skip! if account.writing_style.present?
    current_step_task.update_to(percent: 25, message: "Searching for training emails...")

    cancel! unless FetchTrainingEmailsService.call(account)
  ensure
    current_step_task.done!
  end

  # Step 5: Generate writing style from training emails
  step :generate_writing_style do
    example_emails = account.example_emails
    skip! if account.example_emails.none? || account.writing_style.present? || example_emails.unprocessed.none?

    current_step_task.update_to(percent: 25, message: "Analyzing writing patterns...")

    generator = WritingStyleGenerator.new(account.owner.email)
    writing_style_content = generator.generate(example_emails)

    current_step_task.update_to(percent: 75, message: "Generating writing style...")

    writing_style = WritingStyle.find_or_initialize_by(account: account)
    writing_style.update!(
      email: account.email,
      content: writing_style_content,
      personality: ""
    )

    example_emails.update_all(processed: true)
  ensure
    current_step_task.done!
  end

  # Step 6: Fetch historical emails
  step :fetch_historical_emails do
    current_step_task.update_to(percent: 25, message: "Searching for historical emails...")

    FetchHistoricalEmailsService.call(account)
  ensure
    current_step_task.done!
  end

  # Step 7: Generate email templates
  step :generate_templates do
    writing_style = account.writing_style

    # Only generate templates if they don't exist
    skip! if writing_style&.email_templates.present?
    skip! if account.email_processing_states.where.not(actual_response: [nil, ""]).none?

    current_step_task.update_to(percent: 25, message: "Analyzing email responses...")

    extractor = ExtractTemplatesService.new(account)
    email_templates = extractor.run

    current_step_task.update_to(percent: 75, message: "Generating email templates...")

    # Create writing style if it doesn't exist
    if writing_style.nil?
      writing_style = account.create_writing_style!(
        email: account.email,
        content: "Generated content",
        personality: ""
      )
    end

    writing_style.update!(email_templates: email_templates)

    current_step_task.update_to(percent: 100, message: "Email templates generated successfully")
  ensure
    current_step_task.done!
  end

  # Step 8: Mark setup complete
  step :complete_setup do
    logger.info "Account setup completed for account #{account.id}"

    current_step_task.update_to(percent: 100, message: "Account setup completed successfully!")

    # The journey completion itself serves as the indicator that setup is complete
    # No need for a separate field since we can check AccountSetupJourneyV2.for_hero(account).completed.any?
  ensure
    current_step_task.done!
  end

  private

  # Broadcast progress updates to the user
  # @param progress [Integer] Progress percentage (0-100)
  # @param message [String] Status message to display
  def broadcast_progress(progress, message)
    Turbo::StreamsChannel.broadcast_update_to(
      [account, "fact_extraction_progress"],
      target: "fact-extraction-progress",
      partial: "onboarding/fact_review/progress",
      locals: {progress: progress, message: message}
    )
  end

  # Get the current step task
  # @return [TaskProgress] The current step's subtask
  attr_reader :current_step_task

  def setup_step_progress(current_step_name)
    @journey_task = TaskProgress.new(
      name: "Setting up your account",
      progress_callback: ->(percent:, message:) {
        # Broadcast overall journey progress
        broadcast_progress(percent, message)
      }
    )
    # Create subtasks for each step
    @step_tasks = step_definitions.map do |step_def|
      [step_def.name, @journey_task.subtask(name: step_def.name.humanize)]
    end.to_h

    @current_step_task = @step_tasks.fetch(current_step_name)

    # Mark subtasks up to current as done
    current_step_index = step_definitions.index { |step_def| step_def.name == current_step_name }
    @step_tasks.values.take(current_step_index).each(&:done!)

    # Start the current step task
    @current_step_task.update_to(percent: 0)
  end
end
