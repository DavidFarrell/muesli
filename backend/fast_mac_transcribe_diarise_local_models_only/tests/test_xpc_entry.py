import io
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4
import pytest
from diarise_transcribe import meeting_lease, xpc_entry


def test_service_requires_pin_before_model_import(monkeypatch, tmp_path):
    monkeypatch.setattr(meeting_lease, '_PROCESS_PIN', None)
    monkeypatch.setattr(sys, 'argv', ['service', 'preflight', str(tmp_path), str(tmp_path), 'both', '', ''])
    with pytest.raises(meeting_lease.MeetingLeaseError, match='independent meeting pin'):
        xpc_entry.main()


@pytest.mark.parametrize('arguments', [[], ['live', '.', '.', 'both', 'audio/../other', str(uuid4())], ['reprocess', '.', '.', 'anything', '', '']])
def test_native_shape_fixed(monkeypatch, arguments):
    monkeypatch.setattr(sys, 'argv', ['service', *arguments])
    with pytest.raises((RuntimeError, meeting_lease.MeetingLeaseError)):
        xpc_entry.main()


def source(folder, source_id):
    folder.mkdir()
    manifest = {'schema_version': 1, 'session_id': source_id, 'revision': 1, 'timeline_offset_us': 0, 'completed': False,
                'streams': {stream: {'sample_rate': 16000, 'channels': 1, 'committed_bytes': 320} for stream in ('system', 'mic')}}
    (folder / 'source-recording.json').write_text(json.dumps(manifest))
    for stream in ('system', 'mic'):
        (folder / f'{stream}.pcm').write_bytes(b'\x01\x00' * 160)


def test_live_control_cannot_replace_admitted_uuid(tmp_path, monkeypatch):
    from diarise_transcribe import muesli_backend as backend
    first, replacement = str(uuid4()).upper(), str(uuid4()).upper()
    folder = tmp_path / 'audio'
    source(folder, replacement)
    metadata = json.dumps({'source_session_id': replacement}).encode()
    framed = backend.HDR_STRUCT.pack(backend.MSG_MEETING_START, 0, 0, len(metadata)) + metadata
    monkeypatch.setattr(backend.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(framed)))
    args = backend.create_parser().parse_args(['--source-recording', '--no-live', '--admitted-source-id', first])
    writer = backend.StdoutWriter(io.StringIO())
    try:
        with pytest.raises(ValueError, match='native-admitted source UUID'):
            backend._run_backend(args, folder, writer)
    finally:
        assert writer.close()


def test_committed_source_uses_container_derivation(tmp_path, monkeypatch):
    from diarise_transcribe import muesli_backend as backend, inference_workspace
    folder, derived = tmp_path / 'audio', tmp_path / 'container'
    derived.mkdir()
    source_id = str(uuid4()).upper()
    source(folder, source_id)
    before = {p.name: p.read_bytes() for p in folder.iterdir()}
    monkeypatch.setattr(inference_workspace, '_directory', derived)
    meta = json.dumps({'source_session_id': source_id}).encode()
    framed = backend.HDR_STRUCT.pack(backend.MSG_MEETING_START, 0, 0, len(meta)) + meta
    framed += backend.HDR_STRUCT.pack(backend.MSG_MEETING_STOP, 0, 0, 0)
    monkeypatch.setattr(backend.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(framed)))
    paths = []
    def process(**kwargs):
        paths.append(Path(kwargs['input_path']))
        assert paths[-1].parent == derived and paths[-1].is_file()
        return SimpleNamespace(turns=[])
    monkeypatch.setattr(backend, 'run_pipeline', process)
    monkeypatch.setattr(backend.TranscriptEmitter, 'emit_transcript', lambda *a, **kw: None)
    args = backend.create_parser().parse_args(['--source-recording', '--no-live', '--admitted-source-id', source_id])
    writer = backend.StdoutWriter(io.StringIO())
    try:
        assert backend._run_backend(args, folder, writer) == 0
    finally:
        assert writer.close()
    assert paths
    assert {p.name: p.read_bytes() for p in folder.iterdir()} == before


def test_source_mode_does_not_mkdir(tmp_path, monkeypatch):
    from diarise_transcribe import muesli_backend as backend
    monkeypatch.setattr(sys, 'argv', ['backend', '--source-recording', '--output-dir', str(tmp_path)])
    monkeypatch.setattr(Path, 'mkdir', lambda *a, **kw: pytest.fail('source mkdir attempted'))
    monkeypatch.setattr(backend, 'preflight', lambda *a, **kw: None)
    monkeypatch.setattr(backend, 'observe_runtime', lambda *a: {})
    monkeypatch.setattr(backend, '_run_backend', lambda *a: 0)
    assert backend.main() == 0
