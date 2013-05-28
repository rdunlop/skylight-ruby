module SpecHelper

  class MockGC

    def enable
    end

    def total_time
      0
    end

    def clear
    end

  end

  def instrument(cat, *args, &blk)
    ActiveSupport::Notifications.instrument(cat, {}, &blk)
  end

  def config
    @config ||= Skylight::Config.new(test_config_values)
  end

  def agent_strategy
    'embedded'
  end

  def log_path
    '-'
  end

  def test_config_values
    @test_config_values ||= {
      authentication: "lulz",
      log: log_path,
      log_level: :debug,
      agent: {
        strategy: agent_strategy,
        interval: 1,
        sockfile_path: tmp
      }.freeze,
      report: {
        host: "localhost",
        port: port,
        ssl: false,
        deflate: false
      }.freeze,
      accounts: {
        host: "localhost",
        port: port,
        ssl: false,
        deflate: false
      }.freeze,
      gc: {
        profiler: gc
      }.freeze
    }.freeze
  end

  def gc
    @gc ||= MockGC.new
  end

end
