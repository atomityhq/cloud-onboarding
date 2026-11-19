#!/usr/bin/env python3
"""Build the Event Grid addon without changing the role-only contracts."""

import argparse
import json
from pathlib import Path

import build as base


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--source", type=Path, default=base.HERE)
    parser.add_argument("--output", type=Path, default=base.HERE)
    args = parser.parse_args()

    prefix, version_args, build_args = base.compiler()
    base.check_compiler_version(prefix, version_args)

    raw = base.compile_template(
        prefix,
        build_args,
        args.source / "eventgrid.bicep",
        )

    data = json.loads(raw)
    params = data["parameters"]

    expected = {
        "storageAccountName",
        "containerName",
        "rootFolderPath",
        "eventSubscriptionName",
        "webhookEndpoint",
        "webhookSecret",
    }

    if set(params) != expected:
        base.die("Unexpected Event Grid parameters")

    if params["webhookSecret"]["type"].lower() != "securestring":
        base.die("webhookSecret must be secureString")

    resources = list(base.walk_resources(data.get("resources")))

    if (
            len(resources) != 1
            or resources[0]["type"]
            != "Microsoft.EventGrid/eventSubscriptions"
    ):
        base.die("The addon must create one Event Grid subscription")

    props = resources[0]["properties"]

    if props["eventDeliverySchema"] != "EventGridSchema":
        base.die("EventGridSchema is required")

    if props["filter"]["includedEventTypes"] != [
        "Microsoft.Storage.BlobCreated"
    ]:
        base.die("Only BlobCreated is allowed")

    destination = props["destination"]

    if destination["endpointType"] != "WebHook":
        base.die("A webhook destination is required")

    mappings = destination["properties"]["deliveryAttributeMappings"]

    if (
            len(mappings) != 1
            or mappings[0]["name"] != "X-Atomity-Webhook-Token"
            or mappings[0]["properties"]["isSecret"] is not True
    ):
        base.die("The secret webhook delivery header is required")

    target = args.output / "atomity-eventgrid.json"

    if args.check:
        if not target.is_file() or target.read_text() != raw:
            base.die(
                "atomity-eventgrid.json is stale; "
                "run build_eventgrid.py"
            )
    else:
        args.output.mkdir(parents=True, exist_ok=True)
        target.write_text(raw)

    print("Event Grid template and contract verified.")


if __name__ == "__main__":
    main()