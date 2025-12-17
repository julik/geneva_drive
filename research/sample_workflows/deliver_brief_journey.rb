class DeliverBriefJourney < StepperMotor::Journey
  alias_method :draft_brief, :hero
  delegate :account, to: :hero

  # TODO: Remove skip_if after brief recovery is complete (PR #1426)
  step :cutover, skip_if: -> { draft_brief.closed? } do
    draft_brief.cutover!

    # Record metrics
    Appsignal.increment_counter("draft_briefs.cutover_count", 1)
    Appsignal.increment_counter("draft_briefs.cutover_count", 1, account_id: draft_brief.account.id)

    email_count = draft_brief.email_processing_states.count
    Appsignal.add_distribution_value("draft_briefs.email_state_count_at_cutover", email_count)
    Appsignal.add_distribution_value("draft_briefs.email_state_count_at_cutover", email_count, account_id: draft_brief.account.id)

    time_remaining_ms = (draft_brief.scheduled_for.utc - draft_brief.closed_before.utc) * 1000
    Appsignal.add_distribution_value("draft_briefs.cutover_to_scheduled_for_ms", time_remaining_ms)
    Appsignal.add_distribution_value("draft_briefs.cutover_to_scheduled_for_ms", time_remaining_ms, account_id: draft_brief.account.id)

    cancel! if email_count.zero?
  end

  step :resummarize_invalid_states do
    # Pause the journey if brief cutovers are disabled (damage control mode)
    pause! unless Flipper.enabled?(:brief_cutovers)

    # Grab the states which will be included in the brief
    states_to_brief_rel = draft_brief.email_processing_states.for_inclusion_in_brief

    # Attempt to resummarize invalid states
    valid_states, invalid_states = states_to_brief_rel.partition(&:valid?)

    # Record the metrics - if there suddenly are spikes in those
    # we will be able to see something is amiss
    Appsignal.increment_counter("draft_briefs.invalid_state_count", invalid_states.length)
    Appsignal.increment_counter("draft_briefs.valid_state_count", valid_states.length)

    Appsignal.add_distribution_value("draft_briefs.invalid_states_per_brief", invalid_states.length)
    Appsignal.add_distribution_value("draft_briefs.valid_states_per_brief", valid_states.length)

    invalid_states.each do |state|
      logger.warn "Invalid email processing state #{state.id}, re-summarizing"
      Rails.error.handle { SummarizeEmailJob.perform_now(state.id, force: true) }
    end

    # Even if forced resummarization fails and becomes a "perform later" - we have done our best,
    # delivering the brief on time is more important than having force-summarized everything
  end

  step :convert_draft_to_brief do
    draft_brief.with_lock do
      # Grab the states which will be included in the brief, only include valid ones
      states_to_brief_rel = draft_brief.email_processing_states.for_inclusion_in_brief
      states_to_brief = states_to_brief_rel.filter(&:valid?)
      cancel! if states_to_brief.none?

      brief = draft_brief.account.briefs.create!
      draft_brief.update!(produced_brief: brief)

      logger.info "Produced Brief #{brief.id} for account #{account.id}"

      # Associate email processing states with the brief.
      # Do so only for states we have managed to re-summarize and thus make valid.
      valid_states_to_brief_rel = states_to_brief_rel.where(id: states_to_brief.map(&:id))
      valid_states_to_brief_rel.update_all(brief_id: brief.id, briefed: true)
    end
    Appsignal.increment_counter("draft_briefs.produced_briefs", 1)

    # Record the delay between the scheduled time of the draft brief and now. This can reveal
    # the delays from the queue, delays for summarizing the email states which were invalid etc.
    delay_ms = (Time.current - draft_brief.scheduled_for) * 1000
    Appsignal.add_distribution_value("draft_briefs.real_brief_creation_delay_ms", delay_ms)
    Appsignal.add_distribution_value("draft_briefs.real_brief_creation_delay_ms", delay_ms, account_id: account.id)
  end

  step :enqueue_gmail_label_syncs do
    # Update labels for all emails, also for invalid ones so that they do disappear from the inbox
    # Use a single job-iteration job to process states in batches with bulk operations, preventing rate limit bursts
    SyncDraftBriefGmailLabelsJob.perform_later(draft_brief)
    # Remove stale "Next Brief" label from old messages that may have been stuck
    RemoveStaleNextBriefLabelJob.perform_later(account)
  end

  step :hydrate_caches_with_render, on_exception: :skip! do
    brief = draft_brief.produced_brief
    user = brief.account.owner

    # Use the user's timezone context for consistent URL generation
    Time.use_zone(user.time_zone) do
      time_param = brief.morning? ? "morning" : "afternoon"
      url = Rails.application.routes.url_helpers.briefs_url(date: brief.date, time: time_param, only_path: true)
      Hydration.get_later(url, user: user)
    end
  end

  step :deliver_brief do
    # In a journey step it is nicer to use `deliver_now` so that we can see "mailer dispatched something
    # to the server" as a completion guarantee, i.e. the mailer didn't crash or didn't start throttling
    # itself for whatever reason. This allows us to fail earlier and also to decide on the actions
    # inside the step. But the fixtures are not quite great for that yet.
    mailer_class = Flipper.enabled?(:new_brief, account.owner) ? BriefMailer : OldBriefMailer
    mailer_class.daily_brief(draft_brief.produced_brief).deliver_later
    Appsignal.increment_counter("draft_briefs.enqueued_email_deliveries", 1)
  end
end
