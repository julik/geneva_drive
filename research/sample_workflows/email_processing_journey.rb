# Journey to handle email processing workflow
#
# This journey orchestrates all the necessary steps to process an email:
# 1. Classify the email using ClassifierService
# 2. Assign to draft brief if BriefAction
# 3. Generate summary if needed
# 4. Create embeddings for non-archived emails
# 5. Handle special cases (briefs@cora.computer, @cora.computer domain)
# 6. Generate response if needed
# 7. Sync with Gmail
# 8. Create todos for self-sent emails
#
# @example Start the journey after email state creation
#   EmailProcessingJourney.create!(hero: email_processing_state)
#
class EmailProcessingJourney < StepperMotor::Journey
  alias_method :email_state, :hero
  delegate :account, to: :email_state

  cancel_if { email_state.nil? || account.nil? }

  # Automatically set Current.account for token usage tracking before each step
  def before_step_starts(step_name)
    Current.account = account
  end

  # Step 1: Classify the email
  step :classify_email do
    skip! if email_state.status != :unprocessed

    logger.info "Running classification for state: #{email_state.id}"
    classifier = ClassifierService.new(email_state)
    classification = classifier.run

    logger.info "Updating state with classification results: category=#{classification.category&.name}, action=#{classification.action&.name}"
    email_state.update!(
      status: :classified,
      needs_response: classification.action.needs_response?,
      category: classification.category,
      category_reason: classification.category_reason,
      action: classification.action
    )
    email_state.reload
  end

  # Step 2: Assign to draft brief if BriefAction
  step :assign_to_draft_brief do
    skip! unless email_state.action.is_a?(Action::BriefAction)
    skip! if email_state.draft_brief_id.present? || email_state.brief_id.present?

    account = email_state.account
    skip! unless account.brief_enabled?

    account.draft_briefs.assign_to_next!(email_processing_state: email_state)
  end

  # Step 3: Generate summary if needed
  step :generate_summary do
    skip! unless email_state.action&.needs_summary?

    logger.info "Generating summary for state: #{email_state.id}"
    SummarizeEmailJob.perform_now(email_state.id)
  end

  # Step 4: Create embeddings for non-archived emails
  step :create_embeddings do
    skip! if email_state.action&.archive?

    EmbedEmailBodyJob.perform_now(email_state.id)
  end

  # Step 5: Handle special cases
  step :handle_special_cases do
    if email_state.from.include?("briefs@cora.computer")
      logger.info "Brief notification email detected for account: #{account.id}"
      range = (email_state.created_at - 60.minutes)..email_state.created_at
      brief = account.briefs.find_by(created_at: range)

      if brief
        logger.info "Associated brief found: #{brief.id}, linking notification email"
        brief.update!(brief_email_processing_state: email_state)
      else
        logger.warn "No matching brief found for notification email: #{email_state.id}"
      end

      email_state.update!(
        status: :skipped,
        error_message: "Email from cora.computer domain",
        action: Action::InboxAction.first
      )
    elsif email_state.from.include?("@cora.computer")
      logger.info "Email from cora.computer domain detected, skipping further processing"
      email_state.update!(
        status: :skipped,
        error_message: "Email from cora.computer domain",
        action: Action::InboxAction.first
      )
      SyncGmailEmailJob.perform_now(email_state)
    end
  end

  # Step 6: Generate response if needed
  step :generate_response do
    skip! if email_state.from.include?("briefs@cora.computer") || email_state.from.include?("@cora.computer")
    skip! unless email_state.needs_response? && email_state.account.draft_emails_enabled

    logger.info "Email needs response, generating response for state: #{email_state.id}"
    GenerateResponseJob.perform_now(email_state)
  end

  # Step 7: Update status for no response needed
  step :update_no_response_status do
    skip! if email_state.from.include?("briefs@cora.computer") || email_state.from.include?("@cora.computer")
    skip! if email_state.needs_response? && email_state.account.draft_emails_enabled

    logger.info "No response needed for state: #{email_state.id}"
    email_state.update!(status: :no_response_needed)
  end

  # Step 8: Sync with Gmail
  step :sync_with_gmail do
    skip! if email_state.from.include?("@cora.computer") # Already handled in special cases

    SyncGmailEmailJob.perform_now(email_state)
  end

  # Step 9: Create todo for self-sent emails
  step :create_self_sent_todo do
    skip! unless account.email == email_state.from && account.email == email_state.to && email_state.body["google.com/calendar"].blank?

    logger.info "Creating todo for self-sent email: #{email_state.id}"
    Todo.create!(
      account: account,
      title: email_state.metadata&.dig("todo_title") || email_state.subject || (email_state.lite_mail&.parsed_mail&.attachments&.any? ? "[📎 #{email_state.lite_mail.parsed_mail.attachments.map(&:filename).join(", ")}] " : "") + (email_state.body&.truncate(10) || ""),
      description: email_state.body,
      email_processing_state: email_state
    )
  end
end
