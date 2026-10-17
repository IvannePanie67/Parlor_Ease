/* ParlorEase - Supabase data layer. Loads after app.js and replaces its localStorage logic. */
const SB_URL="https://zgnzzzhlsggivlbouwpe.supabase.co";
const SB_KEY="sb_publishable_KWxHeBWHOxK9BxcplnZvjw__iN9SP0v"; // public key; never put a service_role key here
const sb=supabase.createClient(SB_URL,SB_KEY);
const TBL={customers:"customers",services:"services",staff:"staff",appointments:"appointments",transactions:"transactions",queue:"service_queue"};
const FORM_KEY={customer:"customers",service:"services",staff:"staff",appointment:"appointments",transaction:"transactions",queue:"queue"};
const ST_UI={available:"Available",busy:"Busy",off_duty:"Off"},ST_DB={Available:"available",Busy:"busy",Off:"off_duty"};
const _ids={};let _next=0;const num=u=>_ids[u]||(_ids[u]=++_next); // keeps the UI's numeric ids; uid holds the real uuid
const cap=s=>s?s[0].toUpperCase()+s.slice(1):"";
const hm=t=>String(t||"").slice(0,5);
const fail=e=>toast(e?.code==="23505"?"That record or time slot already exists.":e?.code==="23503"?"Can't delete: it is used by other records.":(e?.message||"Something went wrong."));
forms.staff=[["name","Full name","text"],["role","Specialty / role","text"],["status","Status","select:Available,Busy,Off"],["email","Staff login email (they must register with it)","email"]];

async function loadAll(){
  const names=["customers","services","staff","appointments","transactions","service_queue"];
  const R=await Promise.all(names.map(t=>sb.from(t).select("*")));
  const bad=R.find(r=>r.error);if(bad)throw bad.error;
  const [C,S,T,A,X,Q]=R.map(r=>r.data||[]);
  const cn={},sn={},tn={};C.forEach(r=>cn[r.id]=r);S.forEach(r=>sn[r.id]=r);T.forEach(r=>tn[r.id]=r);
  db.customers=C.map(r=>({id:num(r.id),uid:r.id,name:r.full_name,phone:r.phone||"",email:r.email,visits:r.visits})).sort((a,b)=>a.name.localeCompare(b.name));
  db.services=S.map(r=>({id:num(r.id),uid:r.id,name:r.name,category:r.category,price:Number(r.price),duration:r.duration_minutes,description:r.description,image_url:r.image_url}));
  db.staff=T.map(r=>({id:num(r.id),uid:r.id,name:r.full_name,role:r.specialty,status:ST_UI[r.status],email:r.email||"",profile_id:r.profile_id}));
  db.appointments=A.map(r=>({id:num(r.id),uid:r.id,customer:cn[r.customer_id]?.full_name||"Customer",customerEmail:cn[r.customer_id]?.email||"",customer_id:r.customer_id,service:sn[r.service_id]?.name||"",service_id:r.service_id,staff:tn[r.staff_id]?.full_name||"",staff_id:r.staff_id,date:r.appointment_date,time:hm(r.appointment_time),status:cap(r.status)}));
  db.transactions=X.map(r=>({id:num(r.id),uid:r.id,customer:cn[r.customer_id]?.full_name||"",service:r.service_name||"",amount:Number(r.amount),date:String(r.paid_at).slice(0,10),method:r.payment_method,receiptNo:r.receipt_number}));
  db.queue=Q.filter(r=>["waiting","serving"].includes(r.status)).sort((a,b)=>(a.priority==="priority"?0:1)-(b.priority==="priority"?0:1)||String(a.joined_at).localeCompare(b.joined_at))
    .map(r=>({id:r.queue_number,uid:r.id,customer:cn[r.customer_id]?.full_name||"Walk-in",service:sn[r.service_id]?.name||"",priority:cap(r.priority),time:new Date(r.joined_at).toTimeString().slice(0,5)}));
}
async function refresh(){try{await loadAll()}catch(e){fail(e)}render()}

async function enter(user,mode){
  const {data:p}=await sb.from("profiles").select("full_name,phone,role").eq("id",user.id).maybeSingle();
  if(!p||(mode&&p.role!==mode))return false;
  try{await loadAll()}catch(e){fail(e);return false}
  const me=db.staff.find(s=>s.profile_id===user.id);
  document.getElementById("landingPage").classList.add("hidden");
  login({role:p.role,name:p.full_name,email:user.email,phone:p.phone||"",staffName:me?.name||p.full_name});
  return true;
}
document.getElementById("loginForm").addEventListener("submit",async e=>{
  e.preventDefault();const err=document.getElementById("authError");err.textContent="";
  const {data,error}=await sb.auth.signInWithPassword({email:document.getElementById("loginEmail").value.trim().toLowerCase(),password:document.getElementById("loginPassword").value});
  if(error){err.textContent=/confirm/i.test(error.message)?"Please confirm your email first (check your inbox).":"The email or password is incorrect.";return}
  if(!await enter(data.user,authMode)){await sb.auth.signOut();err.textContent="This account is not a "+authMode+" account."}
});
document.getElementById("registerForm").addEventListener("submit",async e=>{
  e.preventDefault();const err=document.getElementById("registerError");err.textContent="";
  const name=document.getElementById("registerName").value.trim(),email=document.getElementById("registerEmail").value.trim().toLowerCase(),phone=document.getElementById("registerPhone").value.trim(),password=document.getElementById("registerPassword").value;
  if(name.length<2||password.length<6){err.textContent="Enter a name and password with at least 6 characters.";return}
  const {data,error}=await sb.auth.signUp({email,password,options:{data:{full_name:name,phone}}});
  if(error){err.textContent=error.message;return}
  if(!data.session){err.textContent="Account created. Confirm your email, then log in.";return}
  await enter(data.user,"customer");
});
async function logout(){await sb.auth.signOut();currentUser=null;Object.keys(db).forEach(k=>db[k]=[]);showLanding()}
sb.auth.getSession().then(({data})=>{if(data.session)enter(data.session.user,null)});

async function saveForm(type,id,fd){
  const obj=Object.fromEntries(fd.entries());
  if(!isAdmin()&&type!=="appointment")return toast("Admin access required.");
  if(type==="customer"&&!/^[A-Za-z .'-]{2,}$/.test(obj.name))return toast("Enter a valid customer name.");
  if(["price","amount"].some(k=>obj[k]!==undefined&&Number(obj[k])<0))return toast("Amounts cannot be negative.");
  const rec=id?db[FORM_KEY[type]].find(x=>x.id===id):null;if(id&&!rec)return;
  const cust=n=>db.customers.find(c=>c.name===n),svc=n=>db.services.find(s=>s.name===n),stf=n=>db.staff.find(s=>s.name===n);
  let table,row;
  if(type==="customer"){table="customers";row={full_name:obj.name.trim(),phone:obj.phone,email:obj.email.trim().toLowerCase()}}
  else if(type==="service"){table="services";row={name:obj.name.trim(),category:obj.category.trim(),price:Number(obj.price),duration_minutes:Math.round(Number(obj.duration))}}
  else if(type==="staff"){table="staff";row={full_name:obj.name.trim(),specialty:obj.role.trim(),status:ST_DB[obj.status],email:(obj.email||"").trim().toLowerCase()||null}}
  else if(type==="appointment"){
    if(!obj.date||obj.date<todayISO())return toast("Choose today or a future date.");
    const sv=svc(obj.service);if(!sv)return toast("Please choose an available service.");
    let cu,st=null,status="pending";
    if(isAdmin()){cu=cust(obj.customer);st=stf(obj.staff);if(rec)status=(rec.status||"Pending").toLowerCase()}
    else cu=db.customers.find(c=>c.email===currentUser.email)||db.customers[0];
    if(!cu)return toast("Customer profile not found.");
    if(st&&db.appointments.some(a=>a.id!==id&&a.date===obj.date&&a.time===obj.time&&a.staff===st.name&&a.status!=="Cancelled"))return toast("That staff member already has an appointment at this time.");
    table="appointments";row={customer_id:cu.uid,service_id:sv.uid,staff_id:st?.uid||null,appointment_date:obj.date,appointment_time:obj.time,status};
  }
  else if(type==="transaction"){table="transactions";row={customer_id:cust(obj.customer)?.uid||null,service_name:obj.service,amount:Number(obj.amount),payment_method:obj.method,paid_at:new Date(obj.date+"T12:00:00").toISOString()}}
  else if(type==="queue"){table="service_queue";const sv=svc(obj.service);if(!sv)return toast("Please choose a service.");row={customer_id:cust(obj.customer)?.uid||null,service_id:sv.uid,priority:obj.priority.toLowerCase(),joined_at:new Date(todayISO()+"T"+obj.time).toISOString()}}
  else return;
  const res=id?await sb.from(table).update(row).eq("id",rec.uid):await sb.from(table).insert(row);
  if(res.error)return fail(res.error);
  let msg=id?"Record updated":type==="appointment"&&!isAdmin()?"Booking request sent for admin approval.":"Record added";
  if(type==="staff"&&row.email){const l=await sb.rpc("link_staff_by_email",{p_email:row.email});if(l.error)fail(l.error);else if(!l.data)msg="Saved. Ask this person to register with that email, then re-save to give them staff access."}
  closeModal();await refresh();toast(msg);
}
async function deleteItem(type,id){
  if(!isAdmin())return toast("Admin access required.");
  const rec=db[type]?.find(x=>x.id===id);if(!rec)return;
  if(!confirm("Delete this record?"))return;
  const {error}=await sb.from(TBL[type]).delete().eq("id",rec.uid);
  if(error)return fail(error);
  await refresh();toast("Record deleted");
}
async function updateAppt(a,patch,msg){const {error}=await sb.from("appointments").update(patch).eq("id",a.uid);if(error)return fail(error);await refresh();toast(msg)}
async function approveAppointment(id){
  if(!isAdmin())return;const a=db.appointments.find(x=>x.id===id);if(!a)return;
  const staffName=a.staff||db.staff.find(s=>s.status==="Available")?.name||"";
  if(staffName&&db.appointments.some(x=>x.id!==id&&x.date===a.date&&x.time===a.time&&x.staff===staffName&&["Pending","Confirmed"].includes(x.status)))return toast("A staff member already has a booking at that time.");
  updateAppt(a,{status:"confirmed",staff_id:db.staff.find(s=>s.name===staffName)?.uid||null},"Appointment approved.");
}
function rejectAppointment(id){if(!isAdmin())return;const a=db.appointments.find(x=>x.id===id);if(a)updateAppt(a,{status:"cancelled"},"Booking request declined.")}
function cancelMyAppointment(id){const a=db.appointments.find(x=>x.id===id&&x.customerEmail===currentUser.email);if(a&&confirm("Cancel this appointment request?"))updateAppt(a,{status:"cancelled"},"Appointment cancelled.")}
function completeStaffAppointment(id){if(!isStaff())return;const a=db.appointments.find(x=>x.id===id&&x.staff===currentUser.staffName);if(!a)return toast("This appointment is not assigned to your account.");updateAppt(a,{status:"completed"},"Appointment marked completed.")}
async function serveNext(){
  const x=db.queue[0];if(!x)return toast("Queue is empty");
  const {error}=await sb.from("service_queue").update({status:"completed",completed_at:new Date().toISOString()}).eq("id",x.uid);
  if(error)return fail(error);toast(`Serving ${x.customer}`);await refresh();
}
