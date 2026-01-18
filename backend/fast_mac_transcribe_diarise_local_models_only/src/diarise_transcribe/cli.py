"""
CLI entry point for diarise-transcribe.

Usage:
    python -m diarise_transcribe --in audio.wav --out transcript.txt
"""

import argparse
import os
import sys
import tempfile
from pathlib import Path
from typing import Optional

from .audio import normalise_audio, check_ffmpeg, get_audio_duration
from .asr import ASRModel, DEFAULT_MODEL
from .diarisation import SortformerDiarizer, MODEL_CONFIGS, DiarSegment
from .merge import (
    merge_transcript_with_diarisation,
    format_text_output,
    format_json_output,
    format_srt_output,
    format_rttm_output,
)


def create_parser() -> argparse.ArgumentParser:
    """Create argument parser."""
    parser = argparse.ArgumentParser(
        description="Transcribe audio with speaker diarisation on Apple Silicon.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    # Basic transcription with diarisation
    python -m diarise_transcribe --in audio.wav --out transcript.txt

    # All output formats
    python -m diarise_transcribe --in audio.wav \\
        --out transcript.txt \\
        --out-json transcript.json \\
        --out-srt transcript.srt \\
        --out-rttm diarisation.rttm

    # Use NVIDIA High quality diarisation model
    python -m diarise_transcribe --in audio.wav --out transcript.txt \\
        --diar-model nvidia_high
        """,
    )

    # Required input
    parser.add_argument(
        "--in", "-i",
        dest="input_file",
        required=True,
        help="Input audio file (any format ffmpeg supports)",
    )

    # Output files
    parser.add_argument(
        "--out", "-o",
        dest="output_text",
        help="Output plain text file with speaker labels",
    )
    parser.add_argument(
        "--out-json",
        dest="output_json",
        help="Output JSON file with words, segments, and turns",
    )
    parser.add_argument(
        "--out-srt",
        dest="output_srt",
        help="Output SRT subtitle file with speaker labels",
    )
    parser.add_argument(
        "--out-rttm",
        dest="output_rttm",
        help="Output RTTM file (diarisation only)",
    )

    # Model options
    parser.add_argument(
        "--diar-backend",
        choices=["senko", "sortformer"],
        default="senko",
        help="Diarisation backend: 'senko' (CoreML pyannote+CAM++, recommended) or "
             "'sortformer' (CoreML Sortformer) (default: senko)",
    )
    parser.add_argument(
        "--diar-model",
        choices=list(MODEL_CONFIGS.keys()),
        default="default",
        help="Diarisation model variant for Sortformer backend (default: %(default)s)",
    )
    parser.add_argument(
        "--asr-model",
        default=DEFAULT_MODEL,
        help=f"ASR model ID (default: {DEFAULT_MODEL})",
    )

    # Language (pass-through to parakeet if supported)
    parser.add_argument(
        "--language",
        default=None,
        help="Language code for ASR (auto-detected if not specified)",
    )

    # Speaker options
    parser.add_argument(
        "--num-speakers",
        type=int,
        default=None,
        help="Expected number of speakers (Sortformer is fixed at 4 speakers, "
             "this option filters output to top N speakers by activity)",
    )

    # Merge options
    parser.add_argument(
        "--gap-threshold",
        type=float,
        default=0.8,
        help="Gap threshold (seconds) for turn splitting (default: 0.8)",
    )
    parser.add_argument(
        "--speaker-tolerance",
        type=float,
        default=0.25,
        help="Tolerance (seconds) for word-to-speaker assignment (default: 0.25)",
    )

    # Debug options
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Keep temporary normalised WAV files for debugging",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="Verbose output",
    )

    return parser


def run_pipeline(
    input_file: str,
    output_text: Optional[str] = None,
    output_json: Optional[str] = None,
    output_srt: Optional[str] = None,
    output_rttm: Optional[str] = None,
    diar_backend: str = "senko",
    diar_model: str = "default",
    asr_model: str = DEFAULT_MODEL,
    language: Optional[str] = None,
    num_speakers: Optional[int] = None,
    gap_threshold: float = 0.8,
    speaker_tolerance: float = 0.25,
    keep_temp: bool = False,
    verbose: bool = False,
) -> None:
    """
    Run the full transcription + diarisation pipeline.

    Args:
        input_file: Path to input audio file
        output_text: Path for text output
        output_json: Path for JSON output
        output_srt: Path for SRT output
        output_rttm: Path for RTTM output
        diar_backend: Diarisation backend ('sortformer' or 'senko')
        diar_model: Diarisation model variant (for Sortformer)
        asr_model: ASR model ID
        language: Language code
        num_speakers: Expected number of speakers
        gap_threshold: Gap threshold for turn splitting
        speaker_tolerance: Tolerance for speaker assignment
        keep_temp: Keep temporary files
        verbose: Verbose output
    """
    # Validate that at least one output is specified
    if not any([output_text, output_json, output_srt, output_rttm]):
        print("Error: At least one output file must be specified", file=sys.stderr)
        print("Use --out, --out-json, --out-srt, or --out-rttm", file=sys.stderr)
        sys.exit(1)

    # Check ffmpeg
    if not check_ffmpeg():
        print("Error: ffmpeg is not installed or not in PATH", file=sys.stderr)
        print("Install with: brew install ffmpeg", file=sys.stderr)
        sys.exit(1)

    # Validate input file
    input_path = Path(input_file).resolve()
    if not input_path.exists():
        print(f"Error: Input file not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    print(f"Input: {input_path}")

    # Step 1: Normalise audio
    print("\n[1/4] Normalising audio to 16kHz mono WAV...")
    temp_wav = normalise_audio(str(input_path))
    duration = get_audio_duration(temp_wav)
    print(f"  Duration: {duration:.2f} seconds")
    print(f"  Temp file: {temp_wav}")

    try:
        # Step 2: Run ASR
        print(f"\n[2/4] Running ASR with {asr_model}...")
        asr = ASRModel(asr_model)
        transcript = asr.transcribe(temp_wav, language=language)
        print(f"  Transcribed {len(transcript.words)} words")
        if verbose and transcript.text:
            preview = transcript.text[:200] + "..." if len(transcript.text) > 200 else transcript.text
            print(f"  Preview: {preview}")

        # Step 3: Run diarisation
        if diar_backend == "senko":
            print("\n[3/4] Running diarisation with Senko (pyannote+CAM++ CoreML)...")
            from .senko_diarisation import SenkoDiarizer
            diarizer = SenkoDiarizer(quiet=not verbose)
            segments = diarizer.diarise(temp_wav)
        else:
            print(f"\n[3/4] Running diarisation with Sortformer {diar_model} model...")
            diarizer = SortformerDiarizer(model_name=diar_model)
            segments = diarizer.diarise(temp_wav)
        print(f"  Found {len(segments)} speaker segments")

        # Filter to top N speakers if requested
        if num_speakers is not None and num_speakers > 0:
            # Count total duration per speaker
            speaker_durations = {}
            for seg in segments:
                speaker_durations[seg.speaker] = (
                    speaker_durations.get(seg.speaker, 0.0) + seg.duration
                )

            # Keep top N speakers
            top_speakers = sorted(
                speaker_durations.keys(),
                key=lambda s: speaker_durations[s],
                reverse=True,
            )[:num_speakers]

            segments = [s for s in segments if s.speaker in top_speakers]
            print(f"  Filtered to {num_speakers} speakers: {top_speakers}")

        # Step 4: Merge ASR with diarisation
        print("\n[4/4] Merging transcript with speaker labels...")
        merged = merge_transcript_with_diarisation(
            transcript,
            segments,
            gap_threshold=gap_threshold,
            speaker_tolerance=speaker_tolerance,
        )
        print(f"  Created {len(merged.turns)} speaker turns")

        # Write outputs
        print("\nWriting outputs...")

        if output_text:
            text_content = format_text_output(merged)
            Path(output_text).write_text(text_content)
            print(f"  Text: {output_text}")

        if output_json:
            json_content = format_json_output(merged)
            Path(output_json).write_text(json_content)
            print(f"  JSON: {output_json}")

        if output_srt:
            srt_content = format_srt_output(merged)
            Path(output_srt).write_text(srt_content)
            print(f"  SRT: {output_srt}")

        if output_rttm:
            filename = input_path.stem
            rttm_content = format_rttm_output(segments, filename)
            Path(output_rttm).write_text(rttm_content)
            print(f"  RTTM: {output_rttm}")

        print("\nDone!")

    finally:
        # Clean up temp file
        if not keep_temp and os.path.exists(temp_wav):
            os.remove(temp_wav)
            if verbose:
                print(f"Cleaned up: {temp_wav}")
        elif keep_temp:
            print(f"Kept temp file: {temp_wav}")


def main():
    """Main entry point."""
    parser = create_parser()
    args = parser.parse_args()

    try:
        run_pipeline(
            input_file=args.input_file,
            output_text=args.output_text,
            output_json=args.output_json,
            output_srt=args.output_srt,
            output_rttm=args.output_rttm,
            diar_backend=args.diar_backend,
            diar_model=args.diar_model,
            asr_model=args.asr_model,
            language=args.language,
            num_speakers=args.num_speakers,
            gap_threshold=args.gap_threshold,
            speaker_tolerance=args.speaker_tolerance,
            keep_temp=args.keep_temp,
            verbose=args.verbose,
        )
    except KeyboardInterrupt:
        print("\nInterrupted by user", file=sys.stderr)
        sys.exit(130)
    except Exception as e:
        print(f"\nError: {e}", file=sys.stderr)
        if "--verbose" in sys.argv or "-v" in sys.argv:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
