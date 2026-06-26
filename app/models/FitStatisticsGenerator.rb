class FitStatisticsGenerator
  def self.generate_fit_stats(upload_root)
    system("amiga fit -i #{upload_root}")
    fit_stats_paths = Dir.glob(upload_root.join('summary', '*_summary.txt'))

    fit_stats_paths
  end
  def self.generate_fit_stats_pool(upload_root)
    system("amiga fit -i #{upload_root} --pool-by 'Ribotype,Isolate'")
    fit_stats_paths = Dir.glob(upload_root.join('summary', '*_summary.txt'))

    fit_stats_paths
  end
end
