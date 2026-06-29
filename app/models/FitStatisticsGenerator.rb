class FitStatisticsGenerator
<<<<<<< HEAD
  def self.generate_fit_stats(upload_root)
    system("amiga fit -i #{upload_root}")
    fit_stats_paths = Dir.glob(upload_root.join('summary', '*_summary.txt'))
=======
  def self.generate_fit_stats(upload_dir)
    system("amiga fit -i #{upload_dir}")
>>>>>>> 9c63dc349 (removed all userexpt commands)

    Dir.glob(upload_dir.join("summary", "*_summary.txt"))
  end
<<<<<<< HEAD
  def self.generate_fit_stats_pool(upload_root)
    system("amiga fit -i #{upload_root} --pool-by 'Ribotype,Isolate'")
    fit_stats_paths = Dir.glob(upload_root.join('summary', '*_summary.txt'))
=======
>>>>>>> 9c63dc349 (removed all userexpt commands)

  def self.generate_fit_stats_pool(upload_dir)
    system("amiga fit -i #{upload_dir} --pool-by 'Ribotype,Isolate'")

    Dir.glob(upload_dir.join("summary", "*_summary.txt"))
  end
<<<<<<< HEAD
end
=======
end
>>>>>>> 9c63dc349 (removed all userexpt commands)
