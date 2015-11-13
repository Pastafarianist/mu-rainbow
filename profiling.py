import os, datetime
import pstats
from cProfile import Profile

import generator

stats_dir = "profiling"
stats_filename = 'profile_%s.pstat' % datetime.datetime.now().isoformat()
stats_path = os.path.join(stats_dir, stats_filename)

if not os.path.exists(stats_dir):
    os.makedirs(stats_dir)

def profile(func, stats_path):
    profiler = Profile()
    try:
        profiler.runcall(func)
    except KeyboardInterrupt:
        profiler.dump_stats(stats_path)
        s = pstats.Stats(stats_path)
        s.strip_dirs().sort_stats("time").print_stats(30)
        raise

profile(generator.main, stats_path)
