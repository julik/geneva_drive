# The dummy app stands in for an Active Job app. Sidekiq is in the bundle for
# the Sidekiq dispatcher's tests, so the install generator writes
# `GenevaDrive.dispatcher = :sidekiq` into the generated initializer. This
# file loads after that one and puts the suite back on Active Job.
GenevaDrive.dispatcher = :active_job
