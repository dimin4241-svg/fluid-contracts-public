#!/usr/bin/env python3
from __future__ import annotations
import json, requests
from eth_utils import keccak

RPCS=["https://ethereum-rpc.publicnode.com","https://rpc.ankr.com/eth"]
DEX_FACTORY="0x91716C4EDA1Fb55e84Bf8b4c7085f84285c19085"
NATIVE="0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"

def sel(s): return "0x"+keccak(text=s)[:4].hex()
def enc(n): return n.to_bytes(32,"big").hex()
def rpc(method,params):
    errs=[]
    for url in RPCS:
        try:
            r=requests.post(url,json={"jsonrpc":"2.0","id":1,"method":method,"params":params},timeout=30); r.raise_for_status(); b=r.json()
            if "error" in b: raise RuntimeError(b["error"])
            return b["result"]
        except Exception as e: errs.append(f"{url}: {e!r}")
    raise RuntimeError("; ".join(errs))
def call(to,data): return rpc("eth_call",[{"to":to,"data":data},"latest"])
def ucall(to,sig,args=""): return int(call(to,sel(sig)+args),16)
def acall(to,sig,args=""): return "0x"+call(to,sel(sig)+args)[-40:]
def words(raw):
    b=bytes.fromhex(raw[2:]); return [b[i:i+32] for i in range(0,len(b),32)]
def addr(ws,i): return "0x"+ws[i][-20:].hex()

def main():
    latest=rpc("eth_getBlockByNumber",["latest",False])
    total=ucall(DEX_FACTORY,"totalDexes()")
    pools=[]; native=[]; errors=[]
    for dex_id in range(1,total+1):
        try:
            dex=acall(DEX_FACTORY,"getDexAddress(uint256)",enc(dex_id))
            ws=words(call(dex,sel("constantsView()")))
            token0,token1=addr(ws,9).lower(),addr(ws,10).lower()
            row={"dex_id":dex_id,"dex":dex,"token0":token0,"token1":token1,"native_is_token0":token0==NATIVE,"native_is_token1":token1==NATIVE}
            pools.append(row)
            if row["native_is_token0"] or row["native_is_token1"]: native.append(row)
        except Exception as e: errors.append({"dex_id":dex_id,"error":repr(e)})
    print(json.dumps({"chain_id":1,"block":int(latest["number"],16),"total_dexes":total,"native_pool_count":len(native),"native_token0_count":sum(x["native_is_token0"] for x in native),"native_token1_count":sum(x["native_is_token1"] for x in native),"native_pools":native,"errors":errors},indent=2))
if __name__=="__main__": main()
