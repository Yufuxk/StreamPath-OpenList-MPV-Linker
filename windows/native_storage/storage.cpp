#include <winsock2.h>
#include <cstdint>
#include <fcntl.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <nfsc/libnfs.h>
#include <curl/curl.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <charconv>
#include <chrono>
#include <cctype>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#define SP_API extern "C" __declspec(dllexport)
extern "C" __declspec(dllimport) void sp_nfs_set_cancel_cb(
  nfs_context* nfs,int (*callback)(void*),void* data);
namespace {
struct Storage {
  int kind;
  smb2_context* smb = nullptr;
  nfs_context* nfs = nullptr;
  CURL* ftp = nullptr;
  std::string root, url, user, password, domain;
  std::atomic<bool> cancelled{false};
  bool passive = true;
  ~Storage() {
    if(smb) smb2_destroy_context(smb);
    if(nfs) nfs_destroy_context(nfs);
    if(ftp) curl_easy_cleanup(ftp);
    std::fill(password.begin(), password.end(), '\0');
  }
};
int nfsCancelled(void* data) {
  return static_cast<Storage*>(data)->cancelled?1:0;
}
std::string quote(const std::string& value) {
  std::string result="\"";
  constexpr char hex[]="0123456789abcdef";
  for(unsigned char c:value) {
    if(c=='"'||c=='\\') { result+='\\'; result+=static_cast<char>(c); }
    else if(c<32) { result+="\\u00";result+=hex[c>>4];result+=hex[c&15]; }
    else result+=static_cast<char>(c);
  }
  return result+'"';
}
char* copy(const std::string& value) {
  auto* result=new char[value.size()+1];
  std::memcpy(result,value.c_str(),value.size()+1);return result;
}
bool safe(const char* path) {
  if(!path || *path=='/' || std::strchr(path,'\\'))return false;
  std::istringstream parts(path);std::string part;
  while(std::getline(parts,part,'/'))if(part==".."||part==".")return false;
  return true;
}
std::string pathFor(Storage* ctx,const char* path) {
  return ctx->root.empty()?path:ctx->root+(ctx->root.back()=='/'?"":"/")+path;
}
int error(int status) { return status==-ENOENT?-2:status==-EACCES||status==-EPERM?-3:-5; }
struct Transfer {Storage* ctx;std::vector<uint8_t> bytes;size_t maximum;bool bounded=false;};
size_t receive(char* data,size_t size,size_t count,void* userdata) {
  auto* target=static_cast<Transfer*>(userdata);
  if(target->ctx->cancelled)return 0;
  const auto n=size*count, remaining=target->maximum-target->bytes.size();
  target->bytes.insert(target->bytes.end(),data,data+std::min(n,remaining));
  if(n>remaining){target->bounded=true;return 0;}return n;
}
int progress(void* userdata,curl_off_t,curl_off_t,curl_off_t,curl_off_t) {
  return static_cast<Storage*>(userdata)->cancelled?1:0;
}
std::string ftpUrl(Storage* ctx,const char* path,bool directory=false) {
  std::string result=ctx->url;
  if(result.back()!='/')result+='/';
  std::istringstream parts(path);std::string part;bool first=true;
  while(std::getline(parts,part,'/')){
    if(!first)result+='/';first=false;
    char* escaped=curl_easy_escape(ctx->ftp,part.c_str(),static_cast<int>(part.size()));
    result+=escaped;curl_free(escaped);
  }
  if(directory && result.back()!='/')result+='/';
  return result;
}
void configureFtp(Storage* ctx,const std::string& url) {
  curl_easy_reset(ctx->ftp);
  curl_easy_setopt(ctx->ftp,CURLOPT_URL,url.c_str());
  curl_easy_setopt(ctx->ftp,CURLOPT_USERNAME,ctx->user.c_str());
  curl_easy_setopt(ctx->ftp,CURLOPT_PASSWORD,ctx->password.c_str());
  curl_easy_setopt(ctx->ftp,CURLOPT_CONNECTTIMEOUT,15L);
  curl_easy_setopt(ctx->ftp,CURLOPT_TIMEOUT,30L);
  curl_easy_setopt(ctx->ftp,CURLOPT_NOSIGNAL,1L);
  curl_easy_setopt(ctx->ftp,CURLOPT_PROTOCOLS_STR,"ftp,ftps");
  curl_easy_setopt(ctx->ftp,CURLOPT_FOLLOWLOCATION,0L);
  curl_easy_setopt(ctx->ftp,CURLOPT_NOPROGRESS,0L);
  curl_easy_setopt(ctx->ftp,CURLOPT_XFERINFOFUNCTION,progress);
  curl_easy_setopt(ctx->ftp,CURLOPT_XFERINFODATA,ctx);
  if(!ctx->passive)curl_easy_setopt(ctx->ftp,CURLOPT_FTPPORT,"-");
}
std::string statJson(uint64_t size,uint64_t modified,bool directory,const std::string& version) {
  return "{\"size\":"+std::to_string(size)+",\"modified\":"+std::to_string(modified)+
    ",\"directory\":"+(directory?"true":"false")+",\"version\":"+(version.empty()?"null":quote(version))+"}";
}
bool parseSize(const std::string& text,uint64_t& size) {
  const auto parsed=std::from_chars(text.data(),text.data()+text.size(),size);
  return parsed.ec==std::errc{}&&parsed.ptr==text.data()+text.size();
}
std::string decodePath(const char* path) {
  if(!path)return {};
  int length=0;char* decoded=curl_easy_unescape(nullptr,path,0,&length);
  std::string result(decoded,static_cast<size_t>(length));curl_free(decoded);return result;
}
bool connectSmb(Storage* ctx) {
  auto* connection=smb2_init_context();if(!connection)return false;
  if(ctx->smb)smb2_destroy_context(ctx->smb);
  ctx->smb=connection;
  smb2_set_timeout(ctx->smb,15);smb2_set_user(ctx->smb,ctx->user.c_str());
  smb2_set_password(ctx->smb,ctx->password.c_str());smb2_set_domain(ctx->smb,ctx->domain.c_str());
  auto* parsed=smb2_parse_url(ctx->smb,ctx->url.c_str());if(!parsed)return false;
  ctx->root=decodePath(parsed->path);const auto share=decodePath(parsed->share);
  const auto status=smb2_connect_share(ctx->smb,parsed->server,share.c_str(),ctx->user.c_str());
  smb2_destroy_url(parsed);return status>=0;
}
bool reconnectSmb(Storage* ctx) {
  if(ctx->cancelled)return false;
  const auto socket=smb2_get_fd(ctx->smb);
  if(socket!=INVALID_SOCKET){
    // libsmb2 的失败上下文可能仍保留已断开的非阻塞 socket。
    char byte=0;const auto status=recv(socket,&byte,1,MSG_PEEK);
    if(status>0||(status==SOCKET_ERROR&&WSAGetLastError()==WSAEWOULDBLOCK))return false;
  }
  return connectSmb(ctx);
}
uint64_t ftpModified(const std::string& text,const char* format,bool inferYear=false) {
  std::tm date{};const auto now=std::time(nullptr);
  if(inferYear){std::tm current{};gmtime_s(&current,&now);date.tm_year=current.tm_year;}
  std::istringstream input(text);input>>std::get_time(&date,format);
  if(input.fail())return 0;
  auto timestamp=_mkgmtime64(&date);
  if(inferYear&&timestamp>now+24*60*60){--date.tm_year;timestamp=_mkgmtime64(&date);}
  return timestamp<0?0:static_cast<uint64_t>(timestamp)*1000;
}
}
SP_API void sp_storage_free(char* data){delete[] data;}
SP_API void sp_storage_close(Storage* ctx){delete ctx;}
SP_API void sp_storage_cancel(Storage* ctx){ctx->cancelled=true;}
SP_API Storage* sp_storage_connect(int kind,const char* url,const char* user,const char* password,
  const char* domain,int version,int uid,int gid,int passive) {
  auto ctx=std::make_unique<Storage>();ctx->kind=kind;
  ctx->user=user;ctx->password=password;ctx->url=url;ctx->domain=domain;ctx->passive=passive!=0;
  if(kind==0) {
    if(!connectSmb(ctx.get()))return nullptr;
  } else if(kind==1) {
    static const auto initialized=curl_global_init(CURL_GLOBAL_DEFAULT);
    if(initialized!=CURLE_OK)return nullptr;
    ctx->ftp=curl_easy_init();if(!ctx->ftp)return nullptr;
  } else if(kind==2) {
    ctx->nfs=nfs_init_context();if(!ctx->nfs)return nullptr;
    nfs_set_timeout(ctx->nfs,15000);nfs_set_uid(ctx->nfs,uid);nfs_set_gid(ctx->nfs,gid);
    nfs_set_autoreconnect(ctx->nfs,0);
    if(nfs_set_version(ctx->nfs,version)<0)return nullptr;
    if(version==4){
      // 每个上下文持有独立的 NFSv4 clientid 与 open-owner 序列。
      static std::atomic<uint64_t> sequence{0};
      const auto name="StreamPath:"+std::to_string(GetCurrentProcessId())+":"+
        std::to_string(std::chrono::system_clock::now().time_since_epoch().count())+":"+
        std::to_string(sequence.fetch_add(1));
      nfs4_set_client_name(ctx->nfs,name.c_str());
    }
    auto* parsed=nfs_parse_url_dir(ctx->nfs,url);if(!parsed)return nullptr;
    const auto status=nfs_mount(ctx->nfs,parsed->server,parsed->path);
    nfs_destroy_url(parsed);if(status<0)return nullptr;
    nfs_set_poll_timeout(ctx->nfs,100);
    sp_nfs_set_cancel_cb(ctx->nfs,nfsCancelled,ctx.get());
  } else return nullptr;
  return ctx.release();
}
SP_API char* sp_storage_stat(Storage* ctx,const char* path) {
  if(!safe(path))return copy("{\"error\":-7}");
  ctx->cancelled=false;
  const auto remote=pathFor(ctx,path);
  if(ctx->smb) {
    smb2_stat_64 st{};auto status=smb2_stat(ctx->smb,remote.c_str(),&st);
    if(status<0&&reconnectSmb(ctx))status=smb2_stat(ctx->smb,remote.c_str(),&st);
    if(status<0)return copy("{\"error\":"+std::to_string(error(status))+"}");
    return copy(statJson(st.smb2_size,st.smb2_mtime*1000,st.smb2_type==SMB2_TYPE_DIRECTORY,
      std::to_string(st.smb2_ino)+":"+std::to_string(st.smb2_size)+":"+std::to_string(st.smb2_mtime)+":"+std::to_string(st.smb2_mtime_nsec)));
  }
  if(ctx->nfs) {
    nfs_stat_64 st{};const auto status=nfs_stat64(ctx->nfs,remote.c_str(),&st);
    if(ctx->cancelled)return copy("{\"error\":-8}");
    if(status<0)return copy("{\"error\":"+std::to_string(error(status))+"}");
    return copy(statJson(st.nfs_size,st.nfs_mtime*1000,(st.nfs_mode&0170000)==0040000,
      std::to_string(st.nfs_ino)+":"+std::to_string(st.nfs_size)+":"+std::to_string(st.nfs_mtime)+":"+std::to_string(st.nfs_mtime_nsec)));
  }
  configureFtp(ctx,ftpUrl(ctx,path));curl_easy_setopt(ctx->ftp,CURLOPT_NOBODY,1L);
  curl_easy_setopt(ctx->ftp,CURLOPT_FILETIME,1L);
  const auto status=curl_easy_perform(ctx->ftp);
  if(ctx->cancelled)return copy("{\"error\":-8}");
  if(status==CURLE_LOGIN_DENIED)return copy("{\"error\":-10}");
  if(status!=CURLE_OK)return copy(std::string("{\"error\":")+(status==CURLE_REMOTE_FILE_NOT_FOUND?"-2":"-5")+"}");
  curl_off_t size=-1,modified=-1;
  curl_easy_getinfo(ctx->ftp,CURLINFO_CONTENT_LENGTH_DOWNLOAD_T,&size);
  curl_easy_getinfo(ctx->ftp,CURLINFO_FILETIME_T,&modified);
  if(size<0)return copy("{\"error\":-4}");
  return copy(statJson(static_cast<uint64_t>(size),modified<0?0:static_cast<uint64_t>(modified)*1000,false,""));
}
SP_API char* sp_storage_list(Storage* ctx,const char* path) {
  if(!safe(path))return copy("{\"error\":-7}");
  ctx->cancelled=false;const auto remote=pathFor(ctx,path);
  std::string result="[";bool first=true;
  auto append=[&](const char* name,bool directory,uint64_t size,uint64_t modified){
    if(std::strcmp(name,".")==0||std::strcmp(name,"..")==0)return;
    if(!first)result+=',';first=false;
    result+="{\"name\":"+quote(name)+",\"directory\":"+(directory?"true":"false")+
      ",\"size\":"+std::to_string(directory?0:size)+",\"modified\":"+std::to_string(modified)+"}";
  };
  if(ctx->smb) {
    auto* dir=smb2_opendir(ctx->smb,remote.c_str());
    if(!dir&&reconnectSmb(ctx))dir=smb2_opendir(ctx->smb,remote.c_str());
    if(!dir)return copy("{\"error\":-5}");
    while(auto* entry=smb2_readdir(ctx->smb,dir)) {
      if(ctx->cancelled){smb2_closedir(ctx->smb,dir);return copy("{\"error\":-8}");}
      if(entry->st.smb2_type!=SMB2_TYPE_LINK)append(entry->name,entry->st.smb2_type==SMB2_TYPE_DIRECTORY,entry->st.smb2_size,entry->st.smb2_mtime*1000);
    }
    smb2_closedir(ctx->smb,dir);
  } else if(ctx->nfs) {
    nfsdir* dir=nullptr;
    const auto status=nfs_opendir(ctx->nfs,remote.empty()?"/":remote.c_str(),&dir);
    if(status<0)return copy("{\"error\":"+std::to_string(ctx->cancelled?-8:error(status))+"}");
    while(auto* entry=nfs_readdir(ctx->nfs,dir)){
      if(ctx->cancelled){nfs_closedir(ctx->nfs,dir);return copy("{\"error\":-8}");}
      if(entry->type==1||entry->type==2)append(entry->name,entry->type==2,entry->size,static_cast<uint64_t>(entry->mtime.tv_sec)*1000);
    }
    nfs_closedir(ctx->nfs,dir);
  } else {
    configureFtp(ctx,ftpUrl(ctx,path,true));curl_easy_setopt(ctx->ftp,CURLOPT_CUSTOMREQUEST,"MLSD");
    Transfer transfer{ctx,{},16*1024*1024,false};
    curl_easy_setopt(ctx->ftp,CURLOPT_WRITEFUNCTION,receive);curl_easy_setopt(ctx->ftp,CURLOPT_WRITEDATA,&transfer);
    auto status=curl_easy_perform(ctx->ftp);bool machineListing=true;
    long response=0;curl_easy_getinfo(ctx->ftp,CURLINFO_RESPONSE_CODE,&response);
    // 仅在服务器明确不支持 MLSD 时使用 Unix LIST。
    if(status!=CURLE_OK&&(response==500||response==502||response==504)){
      machineListing=false;transfer.bytes.clear();transfer.bounded=false;
      curl_easy_setopt(ctx->ftp,CURLOPT_CUSTOMREQUEST,"LIST");
      status=curl_easy_perform(ctx->ftp);
    }
    if(ctx->cancelled)return copy("{\"error\":-8}");
    if(status==CURLE_LOGIN_DENIED)return copy("{\"error\":-10}");
    if(status!=CURLE_OK)return copy("{\"error\":-5}");
    std::istringstream lines(std::string(transfer.bytes.begin(),transfer.bytes.end()));std::string line;
    while(std::getline(lines,line)){
      if(!line.empty()&&line.back()=='\r')line.pop_back();
      if(!machineListing){
        std::istringstream fields(line);std::string mode,links,owner,group,sizeText,month,day,date,name;
        uint64_t size=0;
        if(!(fields>>mode>>links>>owner>>group>>sizeText>>month>>day>>date)||
           fields.get()!=' '||!parseSize(sizeText,size))return copy("{\"error\":-9}");
        std::getline(fields,name);
        if(mode[0]=='l')continue;
        if((mode[0]!='-'&&mode[0]!='d')||name.empty())return copy("{\"error\":-9}");
        const auto dateText=month+" "+day+" "+date;
        const auto modified=date.find(':')==std::string::npos?ftpModified(dateText,"%b %d %Y"):
          ftpModified(dateText,"%b %d %H:%M",true);
        append(name.c_str(),mode[0]=='d',size,modified);continue;
      }
      const auto separator=line.find(' ');if(separator==std::string::npos)return copy("{\"error\":-9}");
      auto facts=line.substr(0,separator);std::transform(facts.begin(),facts.end(),facts.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
      if(facts.find("type=cdir;")!=std::string::npos||facts.find("type=pdir;")!=std::string::npos)continue;
      if(facts.find("type=file;")==std::string::npos&&facts.find("type=dir;")==std::string::npos)continue;
      uint64_t size=0,modified=0;std::istringstream factFields(facts);std::string fact;
      while(std::getline(factFields,fact,';')){
        if(fact.compare(0,5,"size=")==0&&!parseSize(fact.substr(5),size))return copy("{\"error\":-9}");
        if(fact.compare(0,7,"modify=")==0)modified=ftpModified(fact.substr(7),"%Y%m%d%H%M%S");
      }
      append(line.substr(separator+1).c_str(),facts.find("type=dir;")!=std::string::npos,size,modified);
    }
  }
  return copy(result+"]");
}
SP_API int sp_storage_read(Storage* ctx,const char* path,uint64_t offset,uint8_t* buffer,uint32_t count) {
  if(!safe(path)||count>1024*1024)return -7;
  ctx->cancelled=false;const auto remote=pathFor(ctx,path);
  if(ctx->smb){
    auto* file=smb2_open(ctx->smb,remote.c_str(),O_RDONLY);
    if(!file&&reconnectSmb(ctx))file=smb2_open(ctx->smb,remote.c_str(),O_RDONLY);
    if(!file)return -5;
    auto status=smb2_pread(ctx->smb,file,buffer,std::min(count,smb2_get_max_read_size(ctx->smb)),offset);
    smb2_close(ctx->smb,file);
    if(status<0&&reconnectSmb(ctx)){
      file=smb2_open(ctx->smb,remote.c_str(),O_RDONLY);if(!file)return -5;
      status=smb2_pread(ctx->smb,file,buffer,std::min(count,smb2_get_max_read_size(ctx->smb)),offset);
      smb2_close(ctx->smb,file);
    }
    return status<0?error(status):status;
  }
  if(ctx->nfs){
    nfsfh* file=nullptr;const auto opened=nfs_open(ctx->nfs,remote.c_str(),O_RDONLY,&file);
    if(opened<0)return ctx->cancelled?-8:error(opened);
    const auto status=nfs_pread(ctx->nfs,file,buffer,std::min<size_t>(count,nfs_get_readmax(ctx->nfs)),offset);
    const auto closed=nfs_close(ctx->nfs,file);
    return ctx->cancelled?-8:status<0?error(status):closed<0?error(closed):status;
  }
  configureFtp(ctx,ftpUrl(ctx,path));
  const auto range=std::to_string(offset)+"-"+std::to_string(offset+count-1);
  curl_easy_setopt(ctx->ftp,CURLOPT_RANGE,range.c_str());
  Transfer transfer{ctx,{},count,false};
  curl_easy_setopt(ctx->ftp,CURLOPT_WRITEFUNCTION,receive);curl_easy_setopt(ctx->ftp,CURLOPT_WRITEDATA,&transfer);
  const auto status=curl_easy_perform(ctx->ftp);
  if(ctx->cancelled)return -8;
  if(status==CURLE_LOGIN_DENIED)return -10;
  if(status==CURLE_REMOTE_FILE_NOT_FOUND)return -2;
  if(status==CURLE_BAD_DOWNLOAD_RESUME||status==CURLE_RANGE_ERROR||status==CURLE_FTP_COULDNT_USE_REST)return -4;
  if(status!=CURLE_OK && !(status==CURLE_WRITE_ERROR&&transfer.bounded))return -5;
  std::memcpy(buffer,transfer.bytes.data(),transfer.bytes.size());return static_cast<int>(transfer.bytes.size());
}
SP_API int sp_storage_create_file(Storage* ctx,const char* path,const uint8_t* bytes,uint32_t count) {
  if(!safe(path)||count>16*1024*1024)return -7;
  if(ctx->ftp)return -11;
  ctx->cancelled=false;const auto remote=pathFor(ctx,path);
  int written=0;
  if(ctx->smb){
    auto* file=smb2_open(ctx->smb,remote.c_str(),O_WRONLY|O_CREAT|O_EXCL);
    if(!file&&reconnectSmb(ctx))file=smb2_open(ctx->smb,remote.c_str(),O_WRONLY|O_CREAT|O_EXCL);
    if(!file)return -3;
    while(written<static_cast<int>(count)){
      const auto n=smb2_pwrite(ctx->smb,file,bytes+written,std::min(count-static_cast<uint32_t>(written),smb2_get_max_write_size(ctx->smb)),static_cast<uint64_t>(written));
      if(n<=0){smb2_close(ctx->smb,file);return -5;}written+=n;
    }
    smb2_close(ctx->smb,file);return 0;
  }
  if(ctx->nfs){
    nfsfh* file=nullptr;const auto opened=nfs_open2(ctx->nfs,remote.c_str(),O_WRONLY|O_CREAT|O_EXCL,0644,&file);
    if(opened<0)return ctx->cancelled?-8:error(opened);
    while(written<static_cast<int>(count)){
      const auto n=nfs_pwrite(ctx->nfs,file,bytes+written,
        std::min<size_t>(count-static_cast<uint32_t>(written),nfs_get_writemax(ctx->nfs)),static_cast<uint64_t>(written));
      if(n<=0||ctx->cancelled){nfs_close(ctx->nfs,file);return ctx->cancelled?-8:n<0?error(n):-5;}written+=n;
    }
    const auto status=nfs_close(ctx->nfs,file);return ctx->cancelled?-8:status<0?error(status):0;
  }
  return -11;
}
