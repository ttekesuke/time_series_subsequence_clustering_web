export interface ScoreEntry {
  time: string
  note: string
  duration: string
  velocity: number
}

export type NoteGroup = {
  pitches: number[];
  duration: number;
};

export type RestGroup = {
  rest: true;
  duration: number;
};

export type Voice = {
  color: string;
  timeline: (NoteGroup | RestGroup)[];
};

export type TimeSignature = {
  numerator: number;
  denominator: number;
};
