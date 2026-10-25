# The dummy app stands in for an Active Job app. Sidekiq is in the bundle for
# the Sidekiq dispatcher's tests, so without this GenevaDrive would pick the
# Sidekiq dispatcher on its own.
GenevaDrive.dispatcher = :active_job
