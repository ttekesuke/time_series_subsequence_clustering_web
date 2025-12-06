# time_series_subsequence_clustering_web

A web application for analyzing, generating, and rendering time-series subsequences. It combines clustering-based insights with generative tools that can also output multi-voice music.

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
