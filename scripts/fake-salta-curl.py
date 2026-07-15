#!/usr/bin/env python3
"""Stateful fake PostgREST endpoint for the Salta TUI acceptance test."""

import json
import os
import sys
import time
import urllib.parse
from pathlib import Path


def parse_config(text):
    options = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        name, raw = line.split("=", 1)
        options.setdefault(name.strip(), []).append(json.loads(raw.strip()))
    return options


stdin = sys.stdin.read()
options = parse_config(stdin)
url = options["url"][-1]
method = options["request"][-1]
headers = options.get("header", [])
body_text = options.get("data-binary", [None])[-1]
body = json.loads(body_text) if body_text is not None else None
parsed = urllib.parse.urlsplit(url)
query = urllib.parse.parse_qs(parsed.query)

record = {
    "argv": sys.argv[1:],
    "stdin": stdin,
    "method": method,
    "headers": headers,
    "body": body,
    "url": url,
}
with Path(os.environ["LEM_YATH_SALTA_CURL_LOG"]).open("a") as stream:
    stream.write(json.dumps(record) + "\n")

path = parsed.path

if path.endswith("/rpc/fuzzy_search_properties"):
    text = body["query_text"]
    if text == "slow":
        time.sleep(2)
        result = [{
            "application_id": "stale-id",
            "application_code": "STALE",
            "applicant_name": "Late stale result",
            "address_line_1": "Old Road",
            "city_town": "Past",
            "county": "Old",
            "eircode": "OLD",
            "application_status": "Stale",
            "similarity": 0.1,
        }]
    elif text == "new":
        result = [{
            "application_id": "new-id",
            "application_code": "NEW",
            "applicant_name": "Newest result",
            "address_line_1": "New Road",
            "city_town": "Future",
            "county": "New",
            "eircode": "NEW",
            "application_status": "Current",
            "similarity": 0.99,
        }]
    elif text == "empty":
        result = []
    elif text == "failure":
        sys.stderr.write("synthetic failure\n")
        raise SystemExit(22)
    else:
        result = [
            {
                "application_id": "app-1",
                "application_code": "APP-001",
                "applicant_name": "Alice Example",
                "address_line_1": "1 Green Road",
                "city_town": "Dublin",
                "county": "Dublin",
                "eircode": "D01TEST",
                "application_status": "Active",
                "similarity": 0.93,
            },
            {
                "application_id": "app-2",
                "application_code": "APP-002",
                "applicant_name": "Bob Example",
                "address_line_1": "2 Green Road",
                "city_town": "Cork",
                "county": "Cork",
                "eircode": "T12TEST",
                "application_status": "Survey",
                "similarity": 0.82,
            },
        ]
elif path.endswith("/rpc/get_reckoner_data"):
    result = [
        {
            "measure_code": "INS",
            "measure_details": "Insulation",
            "variated_quantity": 2,
            "seai_rate": "1000.00",
            "tcb_rate": "600.00",
            "revenue": "2000.00",
            "cost": "1200.00",
            "profit": "800.00",
        },
        {
            "measure_code": "SOL",
            "measure_details": "Solar",
            "variated_quantity": 1,
            "seai_rate": "1500.00",
            "tcb_rate": "1000.00",
            "revenue": "1500.00",
            "cost": "1000.00",
            "profit": "500.00",
        },
    ]
elif path.endswith("/rpt_applications"):
    app_id = query.get("application_id", [""])[0].removeprefix("eq.")
    code = {"app-1": "APP-001", "app-2": "APP-002"}.get(app_id, app_id)
    result = [{
        "application_id": app_id,
        "application_code": code,
        "applicant_name": "Alice Example",
        "applicant_email": "alice@example.invalid",
        "address_line_1": "1 Green Road",
        "address_line_2": "",
        "address_line_3": "",
        "address_line_4": "",
        "city_town": "Dublin",
        "county": "Dublin",
        "eircode": "D01TEST",
        "mprn": "100000001",
        "lot_number": "LOT-1",
        "application_status": "Active",
        "drawdown_code": "DD-1",
        "townlink_ref": "TL-1",
        "project_manager": "Pat Manager",
        "measure_count": 1,
        "install_end_date": "2026-07-01",
    }]
elif path.endswith("/rpt_application_measures"):
    result = [{
        "measure_code": "INS",
        "measure_details": "Insulation",
        "measure_category": "Fabric",
        "measure_unit": "m2",
        "survey_quantity": 2,
        "variated_quantity": 2,
        "inspection_quantity": 2,
    }]
elif path.endswith("/rpt_claim_lines"):
    result = [{
        "claim_item_id": "claim-1",
        "contractor_name": "Acme",
        "reference_number": "REF-1",
        "measure_code": "INS",
        "measure_details": "Insulation",
        "claimed_quantity": 2,
        "approved_quantity": 2,
        "rate_amount": "600.00",
        "committed_value": "1200.00",
        "is_frozen": True,
    }]
elif path.endswith("/rpt_payments"):
    result = [{
        "pay_commit_id": "pay-1",
        "contractor_name": "Acme",
        "application_code": "APP-001",
        "percentage": "50",
        "total_committed_value": "1200.00",
        "pay_amount": "600.00",
        "payment_run_label": "RUN-1",
        "created_at": "2026-07-15T10:00:00Z",
    }]
elif path.endswith("/contractors"):
    result = [{
        "contractor_id": "contractor-1",
        "contractor_name": "Acme",
        "contractor_code": "AC",
        "is_active": True,
    }]
elif path.endswith("/rate_cards"):
    result = [{"rate_card_id": "card-1", "label": "July 2026"}]
elif path.endswith("/rates"):
    result = [{
        "rate_id": "rate-1",
        "measure_code": "INS",
        "rate_amount": "600.00",
        "rate_unit": "m2",
    }]
elif path.endswith("/rpt_contractor_financials"):
    result = [{
        "contractor_name": "Acme",
        "contractor_code": "AC",
        "is_active": True,
        "submission_count": 3,
        "claim_item_count": 4,
        "application_count": 2,
        "total_committed_value": "1200.00",
        "total_paid_amount": "600.00",
        "outstanding_amount": "600.00",
    }]
else:
    sys.stderr.write(f"unhandled fake Salta URL: {url}\n")
    raise SystemExit(22)

sys.stdout.write(json.dumps(result))
