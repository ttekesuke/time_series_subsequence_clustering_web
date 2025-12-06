# time_series_subsequence_clustering_web

A web application for analyzing, generating, and rendering time-series subsequences. It scans incoming sequences from the start to uncover recurring motifs, combines clustering-based insights with generative tools, and can output multi-voice music.

## How it works

1. **Sequential scanning & clustering:** Every series is scanned from the beginning so early motifs are captured. The pipeline clusters similar subsequences across a wide range of lengths, exposing both short patterns and longer-term repetitions.
2. **Complexity measurement:** The clustering results are used to estimate structural complexity. This metric serves as a guide for generation tasks and for comparing candidate outputs.
3. **Search-based generation:** When provided with a target progression of complexity values, the system enumerates candidate sequences, measures each one’s complexity, and returns the options that best fit the requested trajectory.
4. **Multi-voice music rendering:** Generated sequences can be translated into music across multiple auditory streams. Pitch, octave, loudness, and timbre are chosen to respect the target complexity transitions while balancing how the combined parts are perceived.

## Pushing changes

This repository is not configured with a remote by default. To push, set your own remote URL once (for example, `git remote add origin <your_repo_url>`) and push the `work` branch explicitly: `git push origin work`.

## Features

- **Time-series clustering:** Scans series from the beginning, groups similar subsequences of various lengths, and surfaces clusters for visual inspection.
- **Complexity-aware generation:** Estimates structural complexity from clustering results. Given a target progression of complexity values, the system searches possible candidates and returns sequences that align with the requested trajectory.
- **Music rendering:** Generates music with multiple auditory streams (voices) using parameters such as pitch, octave, loudness, and timbre that follow the supplied complexity transitions. The arrangement considers how the combined streams will be perceived.
- **Web experience:** Built with Vue and Vuetify on the frontend, backed by Rails APIs and SuperCollider rendering for polyphonic output.

## Development

- Vue 3 + TypeScript frontend served via Vite.
- Ruby on Rails backend with ActionCable channels for job progress updates.
- SuperCollider integration for rendering polyphonic audio from generated sequences.

## Deployment

The production instance is available at [time-series-subsequence-clustering-web.onrender.com](https://time-series-subsequence-clustering-web.onrender.com/).
