"""Submit one existing immutable fixture using a local Producer account."""
import argparse
import getpass
import json
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ai_vision.pipelines.vision_producer_client import EmulatorProducerAuth, ProducerError, VisionEvent, VisionProducerClient


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-url", required=True)
    parser.add_argument("--binding", type=Path, required=True, help="Server-created Binding JSON")
    parser.add_argument("--event", type=Path, required=True, help="Existing Envelope JSON; never retimestamped")
    parser.add_argument("--email", required=True)
    args = parser.parse_args()
    auth = EmulatorProducerAuth(project_id="demo-mobi-local")
    client = None
    try:
        auth.login(args.email, getpass.getpass("Local Producer password: "))
        client = VisionProducerClient(args.backend_url, auth)
        client.attach_binding(json.loads(args.binding.read_text(encoding="utf-8")))
        event = VisionEvent(args.event.read_bytes())
        print(json.dumps(client.send(event), ensure_ascii=False))
    except ProducerError as exc:
        print(f"{exc.code}; HTTP={exc.status}; uncertain={exc.uncertain}", file=sys.stderr)
        return 1
    finally:
        if client: client.close()
        auth.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
