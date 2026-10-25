class GenevaDrive::Engine < ::Rails::Engine
  isolate_namespace GenevaDrive

  # Sidekiq fires :quiet on TSTP (what Enterprise rolling restarts send first)
  # and at the start of every shutdown. Resumable steps then checkpoint and
  # hand off to a successor execution instead of being killed mid-iteration
  # when the shutdown timeout runs out. Installed whichever dispatcher is in
  # use - Active Job on the Sidekiq adapter needs it just as much.
  initializer "geneva_drive.sidekiq_lifecycle" do
    if defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)
      ::Sidekiq.configure_server do |config|
        config.on(:quiet) { GenevaDrive.request_exit! }
      end
    end
  end
end
