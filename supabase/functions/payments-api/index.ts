// LearnDrive 2.0 payments API. SANDBOX ONLY until production release controls are approved.
// Internal LearnDrive diary is authoritative. No external calendar sync.
type PayEnv = (name:string)=>string|undefined;
type PayJson = Record<string,any>;
const payVersion='2.0.0.sandbox.1';
export const stripeVersion='2026-08-26.dahlia';
const payUUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
class PaymentError extends Error {
  constructor(public code:string, message:string, public status=400){super(message);}
}
function rejectPayment(code:string,message:string,status=400):never{throw new PaymentError(code,message,status);}
function payRequired(env:PayEnv,key:string):string{
  const value=env(key)?.trim();
  if(!value) rejectPayment('setup_required','Payment setup is not available yet.',503);
  return value;
}
function payId(value:unknown):string{
  if(typeof value!=='string'||!payUUID.test(value)) rejectPayment('invalid_request','Check your booking details.');
  return value;
}
function jsonPayment(value:unknown,status=200):Response{
  return Response.json(value,{status,headers:{'Cache-Control':'no-store','X-LearnDrive-Payments-Version':payVersion}});
}
export function paymentMode(env:PayEnv):'sandbox'{
  const mode=env('PAYMENTS_MODE')?.trim()||'sandbox';
  if(mode!=='sandbox')rejectPayment('sandbox_required','Live payments are not enabled for LearnDrive 2.0 yet.',503);
  return 'sandbox';
}
export function stripeKey(env:PayEnv):string {
  paymentMode(env);
  const key=payRequired(env,'STRIPE_SECRET_KEY');
  if(!/^(sk|rk)_test_[A-Za-z0-9]+$/.test(key))
    rejectPayment('sandbox_required','LearnDrive 2.0 currently accepts Stripe test keys only.',503);
  return key;
}
// Kept for tools that explicitly validate a sandbox key.
export function sandboxKey(env:PayEnv):string{
  if(paymentMode(env)!=='sandbox')rejectPayment('sandbox_required','A sandbox key is required.',503);
  return stripeKey(env);
}
function integration(env:PayEnv):string{paymentMode(env);return 'learndrive_2_sandbox_v1';}
class PayDatabase{
  constructor(private env:PayEnv,private fetcher:typeof fetch){}
  async call(path:string,body?:unknown):Promise<any>{
    const key=payRequired(this.env,'SUPABASE_SERVICE_ROLE_KEY');
    const r=await this.fetcher(`${payRequired(this.env,'SUPABASE_URL')}/rest/v1/${path}`,{
      method:body===undefined?'GET':'POST',headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'},
      body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(12000),redirect:'error',
    });
    if(!r.ok){
      let message='';try{message=(await r.json()).message;}catch{/* Never return a raw database response. */}
      const safe=['This time is unavailable','Finish or cancel your pending payment first','Outside instructor lesson hours','Checkout expired','Instructor payments unavailable','Instructor unavailable','Reservation request already used'];
      if(safe.includes(message)) rejectPayment('booking_unavailable',message+'.',409);
      rejectPayment('service_unavailable','The booking service could not finish. Please retry.',503);
    }
    const text=await r.text();return text?JSON.parse(text):null;
  }
  rows(table:string,filter:PayJson):Promise<PayJson[]>{return this.call(`${table}?${new URLSearchParams(filter)}`);}
  rpc(name:string,args:PayJson):Promise<any>{return this.call(`rpc/${name}`,args);}
}
class StripeGateway{
  constructor(private env:PayEnv,private fetcher:typeof fetch){}
  call(path:string,fields?:Record<string,string>,idempotency?:string,account?:string):Promise<PayJson>{
    if(!/^\/[a-z0-9_/?=&]+$/i.test(path)) throw new Error('Invalid Stripe path');
    if(account&&!/^acct_[A-Za-z0-9]+$/.test(account)) throw new Error('Invalid Stripe account');
    return this.send(`/v1${path}`,fields?new URLSearchParams(fields):undefined,
      'application/x-www-form-urlencoded',idempotency,account);
  }
  v2(path:'/core/accounts'|'/core/account_links',body:PayJson,idempotency?:string):Promise<PayJson>{
    return this.send(`/v2${path}`,JSON.stringify(body),'application/json',idempotency);
  }
  private async send(path:string,body:BodyInit|undefined,contentType:string,idempotency?:string,account?:string):Promise<PayJson>{
    const r=await this.fetcher(`https://api.stripe.com${path}`,{
      method:body===undefined?'GET':'POST',headers:{Authorization:`Bearer ${stripeKey(this.env)}`,'Stripe-Version':stripeVersion,
        ...(body===undefined?{}:{'Content-Type':contentType}),...(idempotency?{'Idempotency-Key':idempotency}:{}),
        ...(account?{'Stripe-Account':account}:{})},
      body,signal:AbortSignal.timeout(20000),redirect:'error',
    });
    if(!r.ok) rejectPayment('stripe_unavailable','Stripe could not finish this request. Please retry.',503);
    const data=await r.json();
    if(typeof data.livemode==='boolean' && data.livemode!==false)
      rejectPayment('environment_mismatch','Stripe returned a different payment environment.',503);
    return data;
  }
}
async function payUser(env:PayEnv,fetcher:typeof fetch,db:PayDatabase,req:Request):Promise<PayJson>{
  const authorization=req.headers.get('Authorization')??'';
  if(!/^Bearer \S+$/.test(authorization)) rejectPayment('sign_in_required','Please sign in again.',401);
  const r=await fetcher(`${payRequired(env,'SUPABASE_URL')}/auth/v1/user`,{
    headers:{Authorization:authorization,apikey:payRequired(env,'SUPABASE_ANON_KEY')},signal:AbortSignal.timeout(10000),redirect:'error',
  });
  if(!r.ok) rejectPayment('sign_in_required','Please sign in again.',401);
  const user=await r.json();payId(user.id);
  const rows=await db.rows('profiles',{id:`eq.${user.id}`,select:'role,account_status'});
  if(!['learner','instructor'].includes(rows[0]?.role)) rejectPayment('account_required','A LearnDrive account is required.',403);
  return {id:user.id,role:rows[0].role,email:user.email,account_status:rows[0].account_status};
}
function payRole(user:PayJson,role:string){if(user.role!==role) rejectPayment('role_required',`An ${role} account is required.`,403);}
function stripeReady(account:PayJson):boolean{
  return account.charges_enabled===true && account.payouts_enabled===true && account.capabilities?.transfers==='active';
}
async function refreshStripeAccount(db:PayDatabase,stripe:StripeGateway,user:string):Promise<PayJson|null>{
  const rows=await db.rows('stripe_instructors',{user_id:`eq.${user}`,select:'account_id'});
  if(!rows.length) return null;
  const account=await stripe.call(`/accounts/${rows[0].account_id}`);
  await db.rpc('payment_save_account',{p_user:user,p_account:account.id,p_ready:stripeReady(account)});
  return account;
}
function checkoutURL(value:unknown):string{
  if(typeof value!=='string') throw new Error('Missing Stripe URL');
  const u=new URL(value);
  if(u.protocol!=='https:'||u.username||u.password||!['checkout.stripe.com','connect.stripe.com','accounts.stripe.com'].includes(u.hostname)) throw new Error('Invalid Stripe URL');
  return u.href;
}
async function readPayBody(req:Request,max:number):Promise<string>{
  if(Number(req.headers.get('content-length')??0)>max) rejectPayment('invalid_request','Request too large.',413);
  const reader=req.body?.getReader();if(!reader)return '';
  const chunks:Uint8Array[]=[];let size=0;
  while(true){const x=await reader.read();if(x.done)break;size+=x.value.length;if(size>max){await reader.cancel();rejectPayment('invalid_request','Request too large.',413);}chunks.push(x.value);}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  return new TextDecoder('utf-8',{fatal:true}).decode(bytes);
}
export async function verifyStripeSignature(raw:string,signature:string|null,secret:string,now=Date.now()):Promise<void>{
  const parts=(signature??'').split(',');const stamps=parts.filter(s=>s.startsWith('t='));
  const signatures=parts.filter(s=>/^v1=[0-9a-f]{64}$/i.test(s)).map(s=>s.slice(3).toLowerCase());
  const timestamp=stamps.length===1?stamps[0].slice(2):'';
  if(!/^\d+$/.test(timestamp)||Math.abs(now/1000-Number(timestamp))>300||!signatures.length||signatures.length>10){
    rejectPayment('invalid_signature','Invalid webhook signature.',400);
  }
  const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(secret),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const digest=new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(`${timestamp}.${raw}`)));
  const hex=Array.from(digest,b=>b.toString(16).padStart(2,'0')).join('');
  let valid=0;for(const candidate of signatures){let difference=0;for(let i=0;i<64;i++)difference|=hex.charCodeAt(i)^candidate.charCodeAt(i);valid|=Number(difference===0);}
  if(!valid)rejectPayment('invalid_signature','Invalid webhook signature.',400);
}
async function ownedCheckout(db:PayDatabase,user:PayJson,id:string):Promise<PayJson>{
  const r=(await db.rows('lesson_reservations',{id:`eq.${id}`,learner_id:`eq.${user.id}`,select:'id,instructor_id'}))[0];
  if(!r) rejectPayment('not_found','Booking not found.',404);
  const c=(await db.rows('stripe_checkouts',{reservation_id:`eq.${id}`,select:'*'}))[0];
  if(!c)rejectPayment('not_found','Booking not found.',404);
  return {...c,instructor_id:r.instructor_id};
}
async function refundBlocked(db:PayDatabase,stripe:StripeGateway,c:PayJson,intent:string):Promise<string>{
  const refund=c.refund_id
    ? await stripe.call(`/refunds/${c.refund_id}`)
    : await stripe.call('/refunds',{payment_intent:intent,reverse_transfer:'true',refund_application_fee:'true'},`ld-refund-${c.reservation_id}`);
  await db.rpc('payment_record_refund',{p_reservation:c.reservation_id,p_refund:refund.id});
  if(refund.status==='succeeded'){
    await db.rpc('payment_refunded',{p_reservation:c.reservation_id,p_refund:refund.id});return 'refunded';
  }
  // Return non-2xx so Stripe retries the same event/idempotent refund. Never
  // acknowledge a failed refund as if the learner had received their money.
  rejectPayment('refund_pending','The refund is awaiting confirmation.',503);
}
async function settleSession(env:PayEnv,fetcher:typeof fetch,db:PayDatabase,stripe:StripeGateway,session:PayJson):Promise<string>{
  if(session.metadata?.integration!==integration(env)) return 'ignored';
  const id=payId(session.metadata?.reservation_id);
  const c=(await db.rows('stripe_checkouts',{reservation_id:`eq.${id}`,select:'*'}))[0];
  if(!c)throw new Error('Unknown reservation');
  if(session.livemode!==false||session.mode!=='payment'||session.currency!=='gbp'||session.amount_total!==c.total_pence
    ||session.client_reference_id!==id||session.metadata.learner_id===undefined) throw new Error('Payment mismatch');
  const r=(await db.rows('lesson_reservations',{id:`eq.${id}`,select:'learner_id,instructor_id,expires_at'}))[0];
  if(!r||r.learner_id!==session.metadata.learner_id) throw new Error('Payment owner mismatch');
  // Authenticated Stripe read can recover the mapping if a webhook beat the
  // original session-creation response, or the database save was interrupted.
  if(c.session_id && c.session_id!==session.id) throw new Error('Payment session mismatch');
  await db.rpc('payment_attach_session',{p_reservation:id,p_session:session.id});
  if(session.status==='expired'){
    await db.rpc('payment_expire',{p_reservation:id,p_session:session.id});return 'expired';
  }
  if(session.status!=='complete'||session.payment_status!=='paid') return 'open';
  const intentId=typeof session.payment_intent==='string'?session.payment_intent:session.payment_intent?.id;
  if(!/^pi_[A-Za-z0-9]+$/.test(intentId??'')) throw new Error('Missing payment');
  const intent=await stripe.call(`/payment_intents/${intentId}`);
  if(intent.livemode!==false||intent.status!=='succeeded'||intent.currency!=='gbp'||intent.amount!==c.total_pence
    ||intent.amount_received!==c.total_pence||intent.application_fee_amount!==c.platform_fee_pence
    ||intent.transfer_data?.destination!==c.account_id||intent.metadata?.reservation_id!==id) throw new Error('Payment mismatch');
  if(c.state==='refunded')return 'refunded';
  if(c.state==='confirmed')return 'confirmed';
  // The database rechecks manual blocks and reservations under the instructor lock.
  const state=await db.rpc('payment_settle',{p_reservation:id,p_session:session.id,p_intent:intentId,
    p_amount:intent.amount_received,p_fee:intent.application_fee_amount,p_destination:intent.transfer_data.destination});
  return state==='refund_pending'?refundBlocked(db,stripe,c,intentId):state;
}
function paymentReturn():Response{
  // A return only opens the app. It never changes payment or booking state.
  // A fixed redirect also works on Supabase's default domain, which may serve
  // HTML function responses as plain text.
  return new Response(null,{status:302,headers:{
    Location:'uk.co.learndrives.app://payments-callback/','Cache-Control':'no-store',
  }});
}
export function createPaymentsHandler(env:PayEnv,fetcher:typeof fetch=fetch){
  return async(req:Request):Promise<Response>=>{
    try{
      const url=new URL(req.url);const path=url.pathname.replace(/^\/functions\/v1/,'').replace(/\/$/,'');
      if(req.method==='GET'&&path==='/payments-api/return')return paymentReturn();
      if(req.method!=='POST')return jsonPayment({error:{code:'method_not_allowed',message:'Use POST.'}},405);
      paymentMode(env);
      const db=new PayDatabase(env,fetcher);const stripe=new StripeGateway(env,fetcher);
      if(path==='/payments-api/webhook'){
        stripeKey(env);
        const raw=await readPayBody(req,262144);
        await verifyStripeSignature(raw,req.headers.get('stripe-signature'),payRequired(env,'STRIPE_WEBHOOK_SECRET'));
        const event=JSON.parse(raw);
        if(event.livemode!==false||typeof event.id!=='string')rejectPayment('invalid_event','The Stripe event environment does not match.');
                        if(['checkout.session.completed','checkout.session.expired','checkout.session.async_payment_succeeded'].includes(event.type)){
          const id=event.data?.object?.id;
          if(!/^cs_test_[A-Za-z0-9]+$/.test(id??''))throw new Error('Invalid session');
          const session=await stripe.call(`/checkout/sessions/${id}`);
          await settleSession(env,fetcher,db,stripe,session);
        }
        return jsonPayment({received:true});
      }
      if(path!=='/payments-api')return jsonPayment({error:{code:'not_found',message:'Not found.'}},404);
      const user=await payUser(env,fetcher,db,req);
      const input=JSON.parse(await readPayBody(req,8192));
      if(!input||Array.isArray(input)||typeof input!=='object')rejectPayment('invalid_request','Invalid request.');
      if(input.environment==='live')rejectPayment('environment_mismatch','This build uses Stripe sandbox payments only.',409);
                  if(user.account_status && user.account_status!=='active' && !['status','list','check','cancel'].includes(input.action))
        rejectPayment('account_closing','Your account deletion request is pending. New bookings and payment setup are disabled.',409);
      // Reading a saved booking does not require a working Stripe key or Stripe request.
      if(input.action==='list')return jsonPayment({bookings:await db.rpc('payment_list',{p_user:user.id}),sandbox:true});
      const enabled=env('STRIPE_PAYMENTS_ENABLED')==='true' && !!env('STRIPE_WEBHOOK_SECRET')?.trim();
      if(input.action==='save_hours'){
        payRole(user,'instructor');
        if(!Array.isArray(input.hours)||input.hours.length>21||input.hours.some((h:any)=>!h||![h.weekday,h.start_minute,h.end_minute].every(Number.isInteger)))
          rejectPayment('invalid_request','Check your lesson hours.');
        await db.rpc('calendar_save_hours',{p_user:user.id,p_hours:input.hours});
        return jsonPayment({saved:true});
      }
      stripeKey(env);
      const endpoint=`${payRequired(env,'SUPABASE_URL')}/functions/v1/payments-api/return`;
      if(input.action==='status'){
        const account=user.role==='instructor'?await refreshStripeAccount(db,stripe,user.id):null;
        const hours=user.role==='instructor'?await db.rows('instructor_lesson_hours',{instructor_id:`eq.${user.id}`,select:'weekday,start_minute,end_minute',order:'weekday'}):[];
        return jsonPayment({sandbox:true,enabled,connected:!!account,ready:!!account&&stripeReady(account),hours});
      }
      if(input.action==='onboard'){
        payRole(user,'instructor');let account=await refreshStripeAccount(db,stripe,user.id);
        if(!account){
          // Recipient accounts require contact_email. Only trust the email
          // returned by Supabase Auth, never an address supplied in the request.
          const email=typeof user.email==='string'?user.email.trim():'';
          if(email.length>254||! /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))
            rejectPayment('contact_email_required','A valid email address is required on your LearnDrive account to connect Stripe.',422);
          // Changed parameters need a new key, stable across retries, rather
          // than replaying the earlier request that omitted contact_email.
          account=await stripe.v2('/core/accounts',{
            contact_email:email,dashboard:'express',identity:{country:'gb'},
            defaults:{currency:'gbp',responsibilities:{fees_collector:'application',losses_collector:'application'}},
            configuration:{
              merchant:{capabilities:{card_payments:{requested:true}}},
              recipient:{capabilities:{stripe_balance:{stripe_transfers:{requested:true}}}},
            },metadata:{learndrive_user:user.id},
          },`ld-account-v2-email-${user.id}`);
          if(!/^acct_[A-Za-z0-9]+$/.test(account.id??'')) throw new Error('Invalid Stripe account');
          // Save immediately. If payout setup or the link fails, reuse this
          // account on retry. Readiness is checked from Stripe after onboarding.
          await db.rpc('payment_save_account',{p_user:user.id,p_account:account.id,p_ready:false});
        }
        // Balance Settings is the supported payout API for Accounts v2.
        // Repeat this safe update on retry so interrupted setup can finish.
        await stripe.call('/balance_settings',{
          'payments[payouts][schedule][interval]':'weekly',
          'payments[payouts][schedule][weekly_payout_days][0]':'monday',
        },undefined,account.id);
        const link=await stripe.v2('/core/account_links',{account:account.id,use_case:{
          type:'account_onboarding',account_onboarding:{configurations:['merchant','recipient'],
            return_url:endpoint,refresh_url:endpoint},
        }});
        return jsonPayment({url:checkoutURL(link.url)});
      }
      if(input.action==='slots'){
        payRole(user,'learner');
        const duration=input.duration_minutes;
        if(!/^\d{4}-\d{2}-\d{2}$/.test(input.day??'')||!Number.isInteger(duration)||duration<30||duration>240||duration%30!==0)
          rejectPayment('invalid_request','Choose a lesson date and duration.');
        if(!enabled)return jsonPayment({slots:[],ready:false,enabled:false});
        const instructor=payId(input.instructor_id);
        const account=await refreshStripeAccount(db,stripe,instructor);
        if(!account||!stripeReady(account))return jsonPayment({slots:[],ready:false,enabled:true});
        return jsonPayment({...await db.rpc('payment_slots',{p_instructor:instructor,p_day:input.day,p_duration_minutes:duration}),enabled});
      }
      if(input.action==='checkout'){
        payRole(user,'learner');if(!enabled)rejectPayment('setup_required','Bookings are not available yet.',503);
        const teacher=payId(input.instructor_id);const request=payId(input.request_id);const duration=input.duration_minutes;
        if(!Number.isInteger(duration)||duration<30||duration>240||duration%30!==0||typeof input.start!=='string'||!Number.isFinite(Date.parse(input.start)))
          rejectPayment('invalid_request','Choose a valid lesson time.');
        const account=await refreshStripeAccount(db,stripe,teacher);
        if(!account||!stripeReady(account))rejectPayment('not_ready','This instructor is not ready to accept payments.',409);
        const c=await db.rpc('payment_prepare',{p_learner:user.id,p_instructor:teacher,p_start:input.start,p_duration_minutes:duration,p_request:request});
        // Use the immutable price snapshot saved by payment_prepare.
                const prices={total_pence:c.total_pence,lesson_pence:c.lesson_pence,booking_fee_pence:c.booking_fee_pence,commission_pence:c.commission_pence,platform_fee_pence:c.platform_fee_pence,instructor_pence:c.instructor_pence};
        if(!['creating','open'].includes(c.state))return jsonPayment({reservation_id:c.reservation_id,state:c.state,...prices});
        let session:PayJson;
        if(c.session_id){session=await stripe.call(`/checkout/sessions/${c.session_id}`);}
        else{
          if(Date.parse(c.checkout_expires_at)<Date.now()+1810000)rejectPayment('checkout_expired','This payment attempt expired. Wait for the hold to expire before choosing again.',409);
          session=await stripe.call('/checkout/sessions',{
            mode:'payment','payment_method_types[0]':'card',currency:'gbp',locale:'en-GB',
            'adaptive_pricing[enabled]':'false',client_reference_id:c.reservation_id,
            'metadata[integration]':integration(env),'metadata[reservation_id]':c.reservation_id,'metadata[learner_id]':user.id,
            'line_items[0][price_data][currency]':'gbp','line_items[0][price_data][unit_amount]':String(c.lesson_pence),
            'line_items[0][price_data][product_data][name]':`${duration===60?'1 hour':duration%60===0?`${duration/60} hours`:`${duration} minute`} driving lesson`,'line_items[0][quantity]':'1',
            'line_items[1][price_data][currency]':'gbp','line_items[1][price_data][unit_amount]':String(prices.booking_fee_pence),
            'line_items[1][price_data][product_data][name]':'Booking fee','line_items[1][quantity]':'1',
            'payment_intent_data[application_fee_amount]':String(c.platform_fee_pence),
            'payment_intent_data[transfer_data][destination]':c.account_id,
            'payment_intent_data[metadata][reservation_id]':c.reservation_id,
            success_url:endpoint,cancel_url:endpoint,expires_at:String(Math.floor(Date.parse(c.checkout_expires_at)/1000)),
          },`ld-checkout-${c.reservation_id}`);
          await db.rpc('payment_attach_session',{p_reservation:c.reservation_id,p_session:session.id});
        }
        if(session.status!=='open')return jsonPayment({reservation_id:c.reservation_id,state:await settleSession(env,fetcher,db,stripe,session),...prices});
        return jsonPayment({reservation_id:c.reservation_id,url:checkoutURL(session.url),state:'open',...prices});
      }
      if(input.action==='check'||input.action==='cancel'){
        payRole(user,'learner');const c=await ownedCheckout(db,user,payId(input.reservation_id));
        if(!c.session_id){
          if(input.action==='cancel'||Date.parse(c.checkout_expires_at)<=Date.now()){
            await db.rpc('payment_expire',{p_reservation:c.reservation_id,p_session:null});
            return jsonPayment({state:'expired'});
          }
          return jsonPayment({state:c.state});
        }
        let session=await stripe.call(`/checkout/sessions/${c.session_id}`);
        if(input.action==='cancel'&&session.status==='open')session=await stripe.call(`/checkout/sessions/${c.session_id}/expire`,{},`ld-expire-${c.reservation_id}`);
        return jsonPayment({state:await settleSession(env,fetcher,db,stripe,session)});
      }
      rejectPayment('invalid_action','Unknown payment action.');
    }catch(error){
      if(error instanceof PaymentError)return jsonPayment({error:{code:error.code,message:error.message}},error.status);
      // No bodies, payment credentials or provider error messages enter logs/responses.
      return jsonPayment({error:{code:'service_unavailable',message:'The payment request could not finish. Please refresh and retry.'}},503);
    }
  };
}

Deno.serve(createPaymentsHandler((name: string) => Deno.env.get(name)));