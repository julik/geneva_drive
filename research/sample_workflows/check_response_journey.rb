class CheckResponseJourney < StepperMotor::Journey
  alias_method :email_processing_state, :hero

  # Check within the first hour
  step(wait: 5.minutes) { enqueue_check_job }

  # Check every 2 hours for the first day
  12.times do
    step(wait: 2.hours) { enqueue_check_job }
  end

  # Check once a day after the first day
  7.times do
    step(wait: 1.day) { enqueue_check_job }
  end

  def enqueue_check_job
    # Cancel if email_processing_state is nil (deleted)
    cancel! if email_processing_state.nil?

    # Cancel if account or source_connected_account is inactive
    cancel! unless email_processing_state.account&.source_connected_account&.active?

    # Cancel if we already have a response
    cancel! if email_processing_state.actual_response.present?

    CheckActualResponseJob.perform_later(email_processing_state.id)
  end
end
