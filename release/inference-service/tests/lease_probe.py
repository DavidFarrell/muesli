"""Actual current package pin, under a separate signed sandbox test parent."""
from pathlib import Path
import fcntl
import json
import os
import sys
import time

runtime = Path(__file__).parent / 'python'
sys.path[:] = [str(runtime/'lib/python3.12'), str(runtime/'lib/python3.12/lib-dynload'),
               str(runtime/'lib/python3.12/site-packages')]
control = Path(sys.argv[1])
try:
    import diarise_transcribe
    from diarise_transcribe.meeting_lease import _PROCESS_PIN
    assert _PROCESS_PIN is not None
    modes = [fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_ACCMODE for fd in _PROCESS_PIN.descriptors]
    print(json.dumps({'pid': os.getpid(), 'state': 'pinned', 'access_modes': modes,
                      'noninheritable': all(not os.get_inheritable(fd) for fd in _PROCESS_PIN.descriptors)}), flush=True)
    while not (control/'release').exists():
        time.sleep(.01)
    _PROCESS_PIN.validate()
    print(json.dumps({'pid': os.getpid(), 'state': 'validated'}), flush=True)
except Exception as error:
    print(json.dumps({'pid': os.getpid(), 'state': 'rejected', 'error': str(error)}), flush=True)
    sys.exit(7)
