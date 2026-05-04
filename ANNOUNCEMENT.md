# Gazebo Performance Profiling: First Pass

As I mentioned in previous PMC meetings, I've started a performance profiling effort for Gazebo.

The full report is available here: [Gazebo Performance Profiling Report (PDF)](https://caguero.github.io/gz-profiling/2026-04-21/findings_report.pdf)

A few things to keep in mind:

- **This is a starting point, not a final profiling product.** My goal is to establish a baseline understanding of where time goes and begin building a repeatable profiling workflow. Both the findings and the methodology will evolve as we gain more experience.

- **The report focuses on discovery, not solutions.** It identifies what's hot and why, but the fix suggestions are preliminary.

- **I tried to automate hotspot detection** using a pipeline of scripts that capture, analyze, and rank optimization targets across multiple dimensions (CPU time, cache behavior, false sharing, scheduling). Whether this scripted approach adds enough value over integrated profiling tools remains an open question. I'm actually considering testing tools like [Intel VTune](https://www.intel.com/content/www/us/en/developer/tools/oneapi/vtune-profiler.html) and [Optick](https://github.com/bombomby/optick) that may be more practical for day-to-day optimization work. I'll keep exploring.

- **AI agents were used extensively** in producing the analysis, scripts, and report content. As usual, something to keep in mind, specially with the proposed fix ideas.

My next step is to pick one or two of the identified hotspots, implement fixes, and use the profiling framework to measure the before/after impact. That validation loop will also tell us whether the current tooling is worth refining or whether I should shift to different profiling approaches.

I hope you find it useful.
