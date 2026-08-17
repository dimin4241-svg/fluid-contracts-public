#!/usr/bin/env python3
from __future__ import annotations

import json, sys, time
from datetime import datetime, timezone
import requests

SELECTOR = "0xe47a882d"
TARGETS = [
("Base",8453,"0x4563134183e45D9502015db14B263E31781099bB"),("Base",8453,"0x983107BB3dcb71f3A30176114D8a17c454A62514"),("Base",8453,"0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6"),("Base",8453,"0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
("Plasma",9745,"0x983107BB3dcb71f3A30176114D8a17c454A62514"),("Plasma",9745,"0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
("Polygon",137,"0xa779B6736385930145F4856226Cd3E3691B72458"),("Polygon",137,"0x4563134183e45D9502015db14B263E31781099bB"),("Polygon",137,"0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6"),("Polygon",137,"0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A"),
("Arbitrum",42161,"0x82C53239c4CFC89A8E55A691422af24c18A944b1"),("Arbitrum",42161,"0x1F0bFd9862ae58208d26db0d80797974434EC013"),("Arbitrum",42161,"0xdC1dF9E55f3B7EBD4F19001b294d1e537320BC2E"),
("Ethereum",1,"0xb210249Bc59FE77D29eb5F0e566D60CB2B010EF1"),("Ethereum",1,"0x9b1f75ea07723F331996831f6d04AD4900d1A3B3"),("Ethereum",1,"0xD2245ee5C3099d65a3d0fdCecA0f71Cc4aA8f0FF"),("Ethereum",1,"0x44aE65F0d82E339c31c3Db9d4f82aB4D5d2B06B2"),("Ethereum",1,"0x10705D774fBE0a3802d7a915E23F6f2c109Fd77f"),("Ethereum",1,"0x7cA3814E21E96758d27e4e07B8d021DE70fC4Db6"),("Ethereum",1,"0x6Ee1e0FC4435571AABd95ecd441dE93C804d7f70"),("Ethereum",1,"0xe3eA95fBd0B27D3fF27e04a43aa5C4361376597c")]
FALLBACK={1:["https://ethereum-rpc.publicnode.com"],8453:["https://base-rpc.publicnode.com"],137:["https://polygon-bor-rpc.publicnode.com"],42161:["https://arbitrum-one-rpc.publicnode.com"],9745:["https://rpc.plasma.to"]}

def url(chain,address):
    return f"https://api.routescan.io/v2/network/mainnet/evm/{chain}/etherscan/api?action=eth_call&data={SELECTOR}&module=proxy&tag=latest&to={address}"

def dec(x):
    v=int(x,16)&0xffffffff
    return v-(1<<32) if v&0x80000000 else v

def call_rpc(s,chain,address):
    body={"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":address,"data":SELECTOR},"latest"]}
    errs=[]
    for rpc in FALLBACK[chain]:
        try:
            r=s.post(rpc,json=body,timeout=25); r.raise_for_status(); j=r.json(); x=j.get("result")
            if isinstance(x,str) and x.startswith("0x"): return x,"fallback:"+rpc
            errs.append(str(j))
        except Exception as e: errs.append(repr(e))
    raise RuntimeError("; ".join(errs))

def main():
    s=requests.Session(); checked=datetime.now(timezone.utc).isoformat(); rows=[]; fails=[]
    for network,chain,address in TARGETS:
        u=url(chain,address); rs_err=None
        try:
            try:
                r=s.get(u,timeout=25); r.raise_for_status(); j=r.json(); x=j.get("result")
                if not (isinstance(x,str) and x.startswith("0x")): raise RuntimeError(str(j))
                source="routescan"
            except Exception as e:
                rs_err=repr(e); x,source=call_rpc(s,chain,address)
            raw=dec(x); rows.append({"network":network,"chain_id":chain,"address":address,"canonical_routescan_url":u,"source":source,"routescan_error":rs_err,"result":x,"raw_int32":raw,"annual_percent":raw/10000,"checked_at_utc":checked})
        except Exception as e:
            fails.append({"network":network,"chain_id":chain,"address":address,"canonical_routescan_url":u,"error":repr(e)})
    nonzero=[r for r in rows if r["raw_int32"]!=0]
    print(json.dumps({"checked_at_utc":checked,"target_count":len(TARGETS),"success_count":len(rows),"failure_count":len(fails),"nonzero":nonzero,"results":rows,"failures":fails},indent=2))
    return 2 if fails else (10 if nonzero else 0)

if __name__=="__main__": raise SystemExit(main())
