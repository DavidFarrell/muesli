"""Fixed native V2 launch contract; package pin precedes all model imports."""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace
from uuid import UUID


def main() -> None:
    # These arguments are constructed by native code after source admission;
    # there is no caller-selected argv, model root or environment in the RPC.
    if len(sys.argv) != 7:
        raise RuntimeError("Invalid native inference request")
    operation, root_name, model_name, stream, component, source_id = sys.argv[1:]
    if operation not in {"preflight", "live", "reprocess"} or stream not in {"system", "mic", "both"}:
        raise RuntimeError("Invalid fixed inference operation")
    from .meeting_lease import require_app_admission, validate_source_path
    require_app_admission(SimpleNamespace(meeting_lease_required=True))
    root = validate_source_path(Path(root_name), meeting_root=True)
    model = Path(model_name)
    if not root.is_dir() or not model.is_absolute() or not model.is_dir():
        raise RuntimeError("Admitted source or sealed model is unavailable")
    if operation == "live":
        if not re.fullmatch(r"audio(?:-session-[1-9][0-9]{0,8})?", component):
            raise RuntimeError("Invalid native live folder")
        if str(UUID(source_id)).upper() != source_id:
            raise RuntimeError("Invalid native live UUID")
        audio = validate_source_path(root / component)
        # Parse the current committed prefix before importing the live model
        # pipeline, then bind the subsequent meetingStart independently too.
        from .source_recording import committed_sources
        committed_sources(audio, source_id)
    elif component or source_id:
        raise RuntimeError("Unexpected live source in non-live request")
    from .local_assets import preflight
    if operation == "preflight":
        from .runtime_identity import observe_runtime
        selected = preflight(str(model), diarisation=True, hashes=True)
        print(json.dumps({"type": "preflight", "ready": True,
                          "identity": observe_runtime(selected)}), flush=True)
        return
    from .inference_workspace import activate
    activate()
    if operation == "live":
        from . import muesli_backend
        sys.argv = ["muesli-backend", "--source-recording", "--output-dir", str(audio),
                    "--asr-model", str(model), "--transcribe-stream", stream, "--live-asr-only",
                    "--emit-meters", "--keep-wav", "--meeting-lease-required",
                    "--admitted-source-id", source_id]
        result = muesli_backend.main()
    else:
        from . import reprocess
        sys.argv = ["muesli-reprocess", str(root), "--asr-model", str(model),
                    "--stream", stream, "--meeting-lease-required"]
        result = reprocess.main()
    if result:
        raise RuntimeError(f"Inference operation returned {result}")
