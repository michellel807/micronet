class FitStatisticsGenerator
  def self.generate_fit_stats(upload_dir)
    system("amiga", "fit", "-i", upload_dir.to_s)

    Dir.glob(upload_dir.join("summary", "*_summary.txt"))
  end

  def self.generate_fit_stats_pool(upload_dir)
    system("amiga", "fit", "-i", upload_dir.to_s, "--pool-by", "Ribotype,Isolate")

    Dir.glob(upload_dir.join("summary", "*_summary.txt"))
  end
end
