"""
Accelerated offline transcription + speaker diarisation for Apple Silicon.

Uses:
- parakeet-mlx for ASR (MLX-accelerated)
- Senko (pyannote+CAM++ CoreML) for speaker diarisation
"""

__version__ = "0.1.0"

# Pin app-admitted source identity before any entry-point/model imports.
from .meeting_lease import pin_process_from_environment as _pin_meeting_process
_pin_meeting_process()

# Establish offline policy before model libraries import their Hub settings.
from .local_runtime import configure as _configure_local_runtime
_configure_local_runtime()
