"""Integration checks against the linked Supabase project.

Creates an isolated test store, exercises real concurrent RPC transactions,
and removes only that store's fixtures in a final cleanup transaction.
Credentials stay in memory and are never printed.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
BASE = "https://tsawtrnveekgcrxqutif.supabase.co"
IDS = {name: str(uuid.uuid4()) for name in (
    "store", "other_store", "supplier", "other_supplier", "period", "other_period",
    "delivery", "receipt_doc", "invoice", "delivery_line", "receipt_line",
    "invoice_line", "receipt", "transaction",
)}
LABEL = "__schema_test_" + IDS["store"][:8]


def sql(statement):
    with tempfile.NamedTemporaryFile(mode="w", suffix=".sql") as handle:
        handle.write(statement)
        handle.flush()
        process = subprocess.run(
            ["supabase", "db", "query", "--remote", "--yes", "--file", handle.name,
             "--output", "json"],
            cwd=ROOT, capture_output=True, text=True,
        )
    if process.returncode:
        raise AssertionError(process.stdout + process.stderr)
    return json.loads(process.stdout).get("rows", [])


keys = json.loads(subprocess.check_output(
    ["supabase", "projects", "api-keys", "--reveal", "--output", "json"],
    cwd=ROOT, text=True, stderr=subprocess.DEVNULL,
))
KEY = next(row["api_key"] for row in keys if row.get("name") == "service_role")


def api(path, body=None):
    request = Request(
        BASE + "/rest/v1/" + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={"apikey": KEY, "Authorization": "Bearer " + KEY,
                 "Content-Type": "application/json"},
    )
    with urlopen(request, timeout=40) as response:
        return json.load(response)


def rpc(name, **body):
    return api("rpc/" + name, body)


def error(code, message, action):
    try:
        action()
    except HTTPError as caught:
        value = json.loads(caught.read())
        assert caught.code == code, value
        assert value.get("message") == message, value
        return value
    raise AssertionError("Expected " + message)


def revision():
    return api("periods?id=eq." + IDS["period"] + "&select=input_revision")[0]["input_revision"]


def approve(key, expected, **extra):
    return rpc("approve_period", p_store=IDS["store"], p_period=IDS["period"],
               p_expected=expected, p_key=key, p_actor_label="DB 검증 작업자", **extra)


def finish():
    value = revision()
    rpc("finish_reconciliation", p_store=IDS["store"], p_period=IDS["period"], p_expected=value)
    return value


def baseline():
    return sql("""select jsonb_build_object(
      'documents',(select jsonb_agg(to_jsonb(d) order by id) from documents d where store_id not in ('%s','%s')),
      'objects',(select jsonb_agg(jsonb_build_object('id',id,'name',name,'metadata',metadata) order by name) from storage.objects where bucket_id='originals')
    ) as data;""" % (IDS["store"], IDS["other_store"]))[0]["data"]


def fixture():
    statements = [
        "begin;",
        f"insert into stores(id,name) values('{IDS['store']}','{LABEL}'),('{IDS['other_store']}','{LABEL}_other');",
        f"insert into suppliers(id,store_id,name) values('{IDS['supplier']}','{IDS['store']}','검증 거래처'),('{IDS['other_supplier']}','{IDS['other_store']}','다른 거래처');",
        f"insert into periods(id,store_id,supplier_id,period_start,period_end) values('{IDS['period']}','{IDS['store']}','{IDS['supplier']}','2026-11-09','2026-11-15'),('{IDS['other_period']}','{IDS['other_store']}','{IDS['other_supplier']}','2026-11-09','2026-11-15');",
    ]
    for document, kind in (("delivery", "DELIVERY"), ("receipt_doc", "RECEIPT"), ("invoice", "INVOICE")):
        digest = hashlib.sha256(document.encode()).hexdigest()
        statements += [
            f"""insert into documents(id,store_id,supplier_id,doc_type,file_hash,storage_path,filename,mime_type,byte_size,extraction_status,period_start,period_end)
             values('{IDS[document]}','{IDS['store']}','{IDS['supplier']}','{kind}','{digest}','{IDS['store']}/{digest}','fixture.png','image/png',1,'COMPLETED','2026-11-09','2026-11-15');""",
            f"insert into period_documents(period_id,document_id) values('{IDS['period']}','{IDS[document]}');",
        ]
    for line, document in (("delivery_line", "delivery"), ("receipt_line", "receipt_doc"), ("invoice_line", "invoice")):
        statements.append(f"""insert into doc_lines(id,store_id,document_id,raw_name,raw_unit,qty_read,unit_price_read,amount_read,source_location)
          values('{IDS[line]}','{IDS['store']}','{IDS[document]}','검증 품목','kg',10,20000,200000,'{{"page":1,"row":1}}');""")
    statements += [
        f"""insert into receipts(id,store_id,doc_line_id,source_line_id,received_qty,unit,confirmed_at,actor_label)
         values('{IDS['receipt']}','{IDS['store']}','{IDS['delivery_line']}','{IDS['receipt_line']}',10,'kg',now(),'검증 작업자');""",
        f"""insert into recon_items(id,store_id,period_id,match_result,fact_status,confirmation_scope,work_status,billed_amount,declared_qty,billed_qty,received_qty,unit,delta_qty,check_amount)
         values('{IDS['transaction']}','{IDS['store']}','{IDS['period']}','MATCHED','OWNER_CONFIRMED','RECEIPTS_INCLUDED','OPEN',200000,10,10,10,'kg',0,0);""",
        f"insert into recon_links(store_id,recon_item_id,doc_line_id,link_type) values('{IDS['store']}','{IDS['transaction']}','{IDS['delivery_line']}','DELIVERY'),('{IDS['store']}','{IDS['transaction']}','{IDS['invoice_line']}','INVOICE');",
        f"insert into recon_links(store_id,recon_item_id,receipt_id,link_type) values('{IDS['store']}','{IDS['transaction']}','{IDS['receipt']}','RECEIPT');",
        "commit;",
    ]
    sql("\n".join(statements))


def cleanup():
    # The postgres migration connection may delete test-only immutable records.
    # Trigger changes and fixture deletes commit atomically, restoring all guards.
    immutable = [
        ("settlement_versions", "immutable_approval"),
        ("confirmations", "immutable_confirmation"),
        ("transaction_memos", "immutable_memo"),
        ("receipts", "immutable_receipt"),
        ("operation_requests", "immutable_request"),
    ]
    store_filter = "'%s','%s'" % (IDS["store"], IDS["other_store"])
    statements = ["begin;"]
    # Reconciliation guards reject edits of approved rows. Reopen only test periods.
    statements.append("update periods set status='REVIEWING' where store_id in (" + store_filter + ");")
    for table, trigger in immutable:
        statements.append(f"alter table {table} disable trigger {trigger};")
    for table in (
        "operation_requests", "settlement_versions", "question_evidence", "questions",
        "payment_applications", "payments", "agent_runs", "confirmations", "transaction_memos",
        "recon_links", "returns", "receipts", "recon_items", "document_upload_requests",
        "period_documents", "doc_lines", "documents", "item_aliases", "store_items",
        "periods", "suppliers",
    ):
        statements.append(f"delete from {table} where store_id in ({store_filter});")
    statements.append(f"delete from stores where id in ({store_filter});")
    for table, trigger in immutable:
        statements.append(f"alter table {table} enable trigger {trigger};")
    statements.append("commit;")
    sql("\n".join(statements))


def main():
    original = baseline()
    fixture()
    try:
        # Cross-store compound FKs, exact-one source, uniqueness and time ranges.
        sql(f"""begin;
        do $$ begin
          begin insert into suppliers(store_id,name) values(gen_random_uuid(),'missing store');
            raise exception 'test failed: orphan'; exception when foreign_key_violation then null; end;
          begin insert into doc_lines(store_id,document_id) values('{IDS['other_store']}','{IDS['delivery']}');
            raise exception 'test failed: cross store'; exception when foreign_key_violation then null; end;
          begin insert into recon_links(store_id,recon_item_id,link_type) values('{IDS['store']}','{IDS['transaction']}','EMPTY');
            raise exception 'test failed: source cardinality'; exception when check_violation then null; end;
          begin insert into recon_links(store_id,recon_item_id,receipt_id,link_type) values('{IDS['store']}','{IDS['transaction']}','{IDS['receipt']}','RECEIPT');
            raise exception 'test failed: duplicate receipt'; exception when unique_violation then null; end;
          begin insert into periods(store_id,supplier_id,period_start,period_end) values('{IDS['store']}','{IDS['supplier']}','2026-11-15','2026-11-09');
            raise exception 'test failed: dates'; exception when check_violation then null; end;
        end $$; rollback;""")
        print("PASS relations, cross-store FKs, source cardinality, duplicate receipt, date checks")
        sql(f"""begin;
        do $$ declare payment uuid; begin
          begin insert into receipts(store_id,doc_line_id,source_line_id,received_qty,unit,confirmed_at,actor_label)
            values('{IDS['store']}','{IDS['delivery_line']}','{IDS['receipt_line']}',10,'kg',now(),'duplicate');
            raise exception 'test failed: repeated source'; exception when unique_violation then null; end;
          begin update documents set storage_path='changed' where id='{IDS['delivery']}';
            raise exception 'test failed: changed original'; exception when raise_exception then
              if sqlerrm<>'IMMUTABLE_ORIGINAL' then raise; end if; end;
          insert into payments(store_id,supplier_id,amount,paid_at) values('{IDS['store']}','{IDS['supplier']}',100,now()) returning id into payment;
          insert into payment_applications(store_id,payment_id,billing_document_id,amount) values('{IDS['store']}',payment,'{IDS['invoice']}',80);
          begin update payment_applications set amount=101 where payment_id=payment;
            raise exception 'test failed: allocation total'; exception when raise_exception then
              if sqlerrm<>'PAYMENT_OVERALLOCATED' then raise; end if; end;
          begin update payments set amount=79 where id=payment;
            raise exception 'test failed: reduced payment'; exception when raise_exception then
              if sqlerrm<>'PAYMENT_OVERALLOCATED' then raise; end if; end;
        end $$; rollback;""")
        print("PASS active receipt source uniqueness, original identity, payment allocation limits")


        expected = finish()
        # Same scope validation is performed before any retry replay.
        error(404, "PERIOD_NOT_FOUND", lambda: rpc(
            "approve_period", p_store=IDS["other_store"], p_period=IDS["period"],
            p_expected=expected, p_key="bad-store", p_actor_label="검증"))
        error(409, "STALE_REVISION", lambda: approve("stale", expected - 1))
        sql(f"update recon_items set match_result='MISMATCH' where id='{IDS['transaction']}';")
        expected = finish()
        error(422, "BLOCKED", lambda: approve("blocked", expected))
        sql(f"update recon_items set match_result='MATCHED' where id='{IDS['transaction']}';")
        print("PASS store scope, stale revision, unresolved approval blocking")
        sql(f"update recon_items set fact_status='CONFLICTING' where id='{IDS['transaction']}';")
        conflicting_revision = finish()
        error(422, "BLOCKED", lambda: approve("conflicting-fact", conflicting_revision))
        sql(f"update recon_items set fact_status='OWNER_CONFIRMED' where id='{IDS['transaction']}';")
        print("PASS conflicting facts block approval")


        memo_args = dict(
            p_store=IDS["store"], p_transaction=IDS["transaction"], p_text="거래처 확인 내용",
            p_mode="TYPED_TEXT", p_expected=revision(), p_key="memo-1", p_actor_label="검증 작업자",
        )
        memo = rpc("save_confirmed_memo", **memo_args)
        after_memo = revision()
        assert rpc("save_confirmed_memo", **memo_args) == memo
        assert revision() == after_memo
        changed = dict(memo_args, p_text="변경 내용")
        error(409, "KEY_REUSE", lambda: rpc("save_confirmed_memo", **changed))
        error(409, "STALE_REVISION", lambda: rpc("save_confirmed_memo", **dict(memo_args, p_key="memo-new")))
        print("PASS confirmed memo replay, changed-body conflict, stale request, unchanged retry revision")

        confirmation = dict(
            p_store=IDS["store"], p_period=IDS["period"], p_expected=revision(), p_key="correction-1",
            p_actor_label="검증 작업자",
            p_body={"kind":"line_correction","source_line_id":IDS["delivery_line"],
                    "corrected_fields":{"qty_corrected":"10"},
                    "evidence_refs":[{"document_id":IDS["delivery"],"line_id":IDS["delivery_line"],
                                      "source_location":{"page":1,"row":1}}]},
        )
        saved = rpc("save_confirmation", **confirmation)
        after_confirmation = revision()
        assert rpc("save_confirmation", **confirmation) == saved
        assert revision() == after_confirmation
        print("PASS correction history and idempotent retry")
        receipt_confirmation = dict(
            p_store=IDS["store"], p_period=IDS["period"], p_expected=revision(), p_key="receipt-correction",
            p_actor_label="검증 작업자",
            p_body={"kind":"receipt_link","source_line_id":IDS["receipt_line"],
                    "target_id":IDS["delivery_line"],"supersedes_receipt_id":IDS["receipt"],
                    "evidence_refs":[{"document_id":IDS["receipt_doc"],"line_id":IDS["receipt_line"],
                                      "source_location":{"page":1,"row":1}}]},
        )
        receipt_result = rpc("save_confirmation", **receipt_confirmation)
        receipt_revision = revision()
        assert rpc("save_confirmation", **receipt_confirmation) == receipt_result
        assert revision() == receipt_revision
        sql(f"update recon_links set receipt_id='{receipt_result['receipt_id']}' where receipt_id='{IDS['receipt']}';")
        assert api("receipts?id=eq." + IDS["receipt"])[0]["received_qty"] == 10
        print("PASS receipt replacement preserves prior event and replays its request")

        corrected_id = str(uuid.uuid4())
        corrected_line = str(uuid.uuid4())
        digest = hashlib.sha256(corrected_id.encode()).hexdigest()
        sql(f"""begin;
          insert into documents(id,store_id,supplier_id,doc_type,file_hash,storage_path,filename,mime_type,byte_size,extraction_status,period_start,period_end)
          values('{corrected_id}','{IDS['store']}','{IDS['supplier']}','CORRECTED_INVOICE','{digest}','{IDS['store']}/{digest}','corrected.png','image/png',1,'COMPLETED','2026-11-09','2026-11-15');
          insert into period_documents(period_id,document_id) values('{IDS['period']}','{corrected_id}');
          insert into doc_lines(id,store_id,document_id,qty_read,unit_price_read,amount_read,raw_unit,source_location)
          values('{corrected_line}','{IDS['store']}','{corrected_id}',10,20000,200000,'kg','{{"page":1,"row":1}}');
          commit;""")
        replacement_args = dict(
            p_store=IDS["store"], p_period=IDS["period"], p_expected=revision(), p_key="replacement",
            p_actor_label="검증 작업자",
            p_body={"kind":"replacement","document_id":corrected_id,"target_id":IDS["invoice"],
                    "evidence_refs":[{"document_id":corrected_id,"line_id":None,
                                      "source_location":{"page":1,"area":"footer"}}]},
        )
        replacement = rpc("save_confirmation", **replacement_args)
        assert rpc("save_confirmation", **replacement_args) == replacement
        assert api("documents?id=eq." + corrected_id)[0]["supersedes_id"] == IDS["invoice"]
        assert api("documents?id=eq." + IDS["invoice"])
        sql(f"""update recon_links set doc_line_id='{corrected_line}' where doc_line_id='{IDS['invoice_line']}';
            update recon_items set fact_status='OWNER_CONFIRMED',work_status='OPEN',blockers='[]' where id='{IDS['transaction']}';""")
        no_agreement_revision = finish()
        blocked = error(422, "BLOCKED", lambda: approve("no-agreement", no_agreement_revision))
        assert "UNCONFIRMED_REPLACEMENT" in blocked["details"]
        sql(f"""update documents set agreement_text='양측 수량 확인 후 수정',agreement_source_location='{{"page":1,"area":"footer"}}' where id='{corrected_id}';""")
        print("PASS corrected invoice scope/history and approval blocked without quantity agreement")


        sql(f"""update recon_items set fact_status='OWNER_CONFIRMED',work_status='OPEN',blockers='[]' where id='{IDS['transaction']}';""")
        sql(f"update doc_lines set source_location=null where id='{IDS['delivery_line']}';")
        missing_location = finish()
        missing = error(422, "BLOCKED", lambda: approve("missing-location", missing_location))
        assert "MISSING_SOURCE_LOCATION" in missing["details"]
        sql(f"""update doc_lines set source_location='{{"page":1,"row":1}}' where id='{IDS['delivery_line']}';""")
        print("PASS approval requires original evidence location")
        expected = finish()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            approvals = list(pool.map(lambda i: approve("parallel-" + str(i), expected), range(8)))
        approval_id = approvals[0]["approval_id"]
        assert {value["approval_id"] for value in approvals} == {approval_id}
        assert len(api("settlement_versions?period_id=eq." + IDS["period"])) == 1
        assert approve("parallel-0", expected) == approvals[0]
        error(409, "KEY_REUSE", lambda: approve("parallel-0", expected, p_actor=str(uuid.uuid4())))
        print("PASS 8 concurrent approvals with distinct keys produce one approval ID")
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            repeated = list(pool.map(lambda _: approve("same-concurrent", expected), range(4)))
        assert {value["approval_id"] for value in repeated} == {approval_id}
        print("PASS 4 concurrent retries with the same key replay one approval")


        snapshot = api("settlement_versions?id=eq." + approval_id)[0]["snapshot"]
        # Add actual new evidence and confirm old successful requests replay their old result.
        sql(f"insert into questions(store_id,period_id,question,status) values('{IDS['store']}','{IDS['period']}','새 확인 항목','NEEDS_INFO');")
        assert revision() > expected
        assert approve("parallel-0", expected)["approval_id"] == approval_id
        error(409, "STALE_REVISION", lambda: approve("new-key-old-revision", expected))
        assert api("settlement_versions?id=eq." + approval_id)[0]["snapshot"] == snapshot
        sql(f"""begin; do $$ begin
          begin update settlement_versions set confirmed_total=1 where id='{approval_id}';
            raise exception 'test failed: snapshot mutation'; exception when raise_exception then
              if sqlerrm<>'IMMUTABLE_HISTORY' then raise; end if; end;
        end $$; rollback;""")
        print("PASS old-key replay after evidence changes, stale new-key rejection, immutable snapshot")
    finally:
        cleanup()
    assert baseline() == original
    print("PASS original documents/Storage unchanged and all isolated fixtures removed")


if __name__ == "__main__":
    main()
