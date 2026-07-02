class FitStatisticsGenerator
  def self.generate_fit_stats(upload_dir)
    system("amiga fit -i #{upload_dir}")

    Dir.glob(upload_dir.join("summary", "*_summary.txt"))
  end

  def self.generate_fit_stats_pool(upload_dir)
    system("amiga fit -i #{upload_dir} --pool-by 'Ribotype,Isolate'")

    Dir.glob(upload_dir.join("summary", "*_summary.txt"))
  end
end
