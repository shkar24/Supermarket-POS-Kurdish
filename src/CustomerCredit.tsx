import {useState,useEffect,useRef} from 'react';
import {supabase} from './supabase';
type Debt={id:string;receipt_number:string;customer_name:string;credit_due:number;credit_received:number;final_amount:number};
const money=(v:number)=>v.toLocaleString('en-US')+' د.ع';
export default function CustomerCredit(){
 const [debts,setDebts]=useState<Debt[]>([]),[page,setPage]=useState(0),[revision,setRevision]=useState(0),[error,setError]=useState(''),[notice,setNotice]=useState(''),[selected,setSelected]=useState<Debt|null>(null),[amount,setAmount]=useState(''),[busy,setBusy]=useState(false),[more,setMore]=useState(false);
 const pending=useRef(false),request=useRef({body:'',id:''});
 useEffect(()=>{let active=true;void supabase?.from('sales').select('id,receipt_number,customer_name,credit_due,credit_received,final_amount').eq('payment_method','credit').gt('credit_due',0).order('created_at',{ascending:false}).order('id').range(page*50,page*50+50).then(({data,error})=>{if(!active)return;if(error){setError(error.message);return}setDebts((data??[]).slice(0,50));setMore((data??[]).length>50)});return()=>{active=false}},[page,revision]);
 async function receive(e:React.FormEvent){e.preventDefault();if(!selected||!supabase||pending.current)return;pending.current=true;setBusy(true);setError('');setNotice('');
 try{const body=JSON.stringify([selected.id,Number(amount)]);if(request.current.body!==body)request.current={body,id:crypto.randomUUID()};
 const {data,error}=await supabase.rpc('collect_customer_payment',{p_sale:selected.id,p_amount:Number(amount),p_request:request.current.id});
 if(error){setError(error.message);return}request.current={body:'',id:''};setNotice('پارەکە وەرگیرا · قەرزی ماوە '+money(Number(data)));setSelected(null);setAmount('');setPage(0);setRevision(v=>v+1)
 }finally{pending.current=false;setBusy(false)}}
 return <section>{error&&<p className="error" role="alert">{error}</p>}{notice&&<p role="status">{notice}</p>}
 {selected&&<form className="manageform" onSubmit={receive}><h3>{selected.customer_name} · {selected.receipt_number}</h3><label>بڕی وەرگیراو<input autoFocus required type="number" min=".01" max={selected.credit_due} step=".01" value={amount} onChange={e=>setAmount(e.target.value)}/></label><button className="primary" disabled={busy}>تۆمارکردنی پارەدان</button><button type="button" disabled={busy} onClick={()=>setSelected(null)}>داخستن</button></form>}
 <div className="table-scroll"><table><thead><tr><th>کڕیار</th><th>وەسڵ</th><th>کۆی فرۆشتن</th><th>وەرگیراو</th><th>قەرزی ماوە</th><th>پارەدان</th></tr></thead><tbody>{debts.map(d=><tr key={d.id}><td>{d.customer_name}</td><td>{d.receipt_number}</td><td>{money(d.final_amount)}</td><td>{money(d.credit_received)}</td><td>{money(d.credit_due)}</td><td><button disabled={busy} onClick={()=>{setSelected(d);setAmount(String(d.credit_due));setNotice('')}}>وەرگرتنی پارە</button></td></tr>)}</tbody></table></div>{!debts.length&&<p>هیچ وەسڵێکی قەرز لەم پەڕەیە نییە.</p>}{(page>0||more)&&<div><button disabled={!page} onClick={()=>setPage(v=>v-1)}>پێشوو</button><button disabled={!more} onClick={()=>setPage(v=>v+1)}>دواتر</button></div>}</section>
}