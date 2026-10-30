// FarCryCoopNet.asi - logger and fix for the snapshot pipeline of CryGame.dll 1.4.0.1405.
// Hooks (addresses found with REA/Ghidra, checked against MOD SDK 1.4 sources):
//   CXSnapshot::BuildAndSendSnapshot  0x3306faba (server)
//   CNetEntityInfo::Update            0x330bb9b7 (server)
//   CNetEntityInfo::Write             0x330bb82d (server)
//   CXServerSlot::SendUnreliableMsg   0x3306c620 (server)
//   CXClient::ParseIncomingStream     0x3308354b (client)
//   CXClient::OnServerMsgTimeStamp    0x33080227 (client)
//   CXClient::OnServerMsgUpdateEntity 0x330816ef (client)
//   GameWarning                       0x3307019e (both; catches "Updated but not spawned")
//   CMovieUser::Begin/EndCutScene     0x330cfd25 / 0x330cfed6 (dedicated server: skipped, it has no input)
//   CryMovie.dll sound track key      0x3401a396 (skipped when there is no sound system)
//   CrySystem.dll node alloc / free   0x36505c27 / 0x365055c8 (under a lock: the sound thread uses them too)
// Fix: sorts the snapshot entity list by priority and keeps each snapshot under the 8992-bit
// unreliable buffer of CryNetwork, so nothing is dropped and held-back entities rotate in.
// Built without the Windows SDK and CRT (none on this PC outside drive C:), see build.ps1.
#include <stdarg.h>

typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned long DWORD;
typedef int BOOL;
typedef void *HANDLE;

#define API(t) __declspec(dllimport) t __stdcall
API(HANDLE) GetModuleHandleA(const char *);
API(DWORD) GetModuleFileNameA(HANDLE, char *, DWORD);
API(void *) VirtualAlloc(void *, DWORD, DWORD, DWORD);
API(BOOL) VirtualProtect(void *, DWORD, DWORD, DWORD *);
API(BOOL) FlushInstructionCache(HANDLE, const void *, DWORD);
API(HANDLE) GetCurrentProcess(void);
API(DWORD) GetCurrentProcessId(void);
API(DWORD) GetCurrentThreadId(void);
API(void) InitializeCriticalSection(void *);
API(void) EnterCriticalSection(void *);
API(void) LeaveCriticalSection(void *);
API(BOOL) TryEnterCriticalSection(void *);
API(HANDLE) CreateThread(void *, DWORD, DWORD(__stdcall *)(void *), void *, DWORD, DWORD *);
API(void) Sleep(DWORD);
API(HANDLE) CreateFileA(const char *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
API(BOOL) WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
API(BOOL) ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
API(BOOL) CloseHandle(HANDLE);
API(BOOL) DeleteFileA(const char *);
API(void *) AddVectoredExceptionHandler(DWORD, long(__stdcall *)(void **));
API(DWORD) GetTickCount(void);
API(BOOL) IsBadReadPtr(const void *, DWORD);
API(BOOL) DisableThreadLibraryCalls(HANDLE);
API(int) lstrcmpiA(const char *, const char *);
API(int) wvsprintfA(char *, const char *, va_list);
API(DWORD) timeBeginPeriod(DWORD);
API(HANDLE) LoadKeyboardLayoutA(const char *, DWORD);
API(HANDLE) GetKeyboardLayout(DWORD);

int _fltused = 1;

// No CRT: the optimizer may still emit calls to memset/memcpy for byte loops.
void *__cdecl memset(void *d, int c, unsigned n)
{
	BYTE *p = (BYTE *)d;
	while (n--)
		*p++ = (BYTE)c;
	return d;
}
void *__cdecl memcpy(void *d, const void *s, unsigned n)
{
	BYTE *p = (BYTE *)d;
	const BYTE *q = (const BYTE *)s;
	while (n--)
		*p++ = *q++;
	return d;
}

#define CRYGAME_BASE 0x33000000u
#define CRYGAME_TIMESTAMP 0x44e2f64du // PE header of the 1.4.0.1405 build
#define CRYMOVIE_BASE 0x34000000u
#define CRYMOVIE_TIMESTAMP 0x44ae37b4u
#define CRYINPUT_BASE 0x33500000u
#define CRYINPUT_TIMESTAMP 0x44ae37bbu
#define CG(va) (g_base + ((va) - CRYGAME_BASE))

static HANDLE g_log = (HANDLE)-1;
static BYTE *g_base, *g_movie; // CryGame.dll, CryMovie.dll
static int g_server;            // running in FarCry_WinSV.exe (set in DllMain)
static DWORD g_snapTick;        // when this process last sent a snapshot (it hosts: dedicated or listen)
static int hosting(void)
{
	return g_server || (g_snapTick && GetTickCount() - g_snapTick < 2000);
}

static void logf(const char *fmt, ...)
{
	char buf[1024 + 2]; // wvsprintfA writes at most 1024 chars
	DWORD n, w;
	va_list va;
	va_start(va, fmt);
	n = (DWORD)wvsprintfA(buf, fmt, va);
	va_end(va);
	buf[n++] = '\r';
	buf[n++] = '\n';
	if (g_log != (HANDLE)-1)
		WriteFile(g_log, buf, n, &w, 0);
}

// ---- per-second counters ----
static struct {
	DWORD snap, snapBits;             // BuildAndSendSnapshot calls, last snapshot size in bits
	DWORD upd, upd0, updHi;           // Update calls, priority 0 (not sent), priority >= 1000000 (slot's own player)
	DWORD plId, plPrio;               // last slot player seen in Update
	DWORD ts, tsIgn; int tsWorld;     // TimeStamp calls, of them set m_bIgnoreSnapshot, last world time
	DWORD ue, ueFail, ueIgn;          // UpdateEntity calls, returned false (packet aborted), read while ignoring
	DWORD myId, ueOwn;                // client: m_wPlayerID, UpdateEntity calls for it
	DWORD idMin, idMax;               // client: range of entity ids peeked from UpdateEntity
	DWORD wr, wrOwn;                  // server: CNetEntityInfo::Write calls (entities really sent), of them slot player
	int px, py, pz;                   // own player position x10 (server: slot player, client: m_wPlayerID)
	DWORD skip, rx, rxMax;            // server: entity updates held back by the budget; client: packets, biggest in bits
	DWORD gap, lastAt;                // longest pause in ms between snapshots (server) / TimeStamps (client)
} s;
static void *(__cdecl *getISystem)(void); // CryGame GetISystem() at 0x330be6e8
#define VFN(obj, off) ((*(void ***)(obj))[(off) / 4])
static DWORD g_lastTick;

static void gap(void) // a stutter shows up as a long pause between two network frames
{
	DWORD now = GetTickCount();
	if (s.lastAt && now - s.lastAt > s.gap)
		s.gap = now - s.lastAt;
	s.lastAt = now;
}

static void tick(void)
{
	DWORD now = GetTickCount();
	if (now - g_lastTick < 1000)
		return;
	g_lastTick = now;
	if (s.snap || s.upd || s.ts || s.ue)
		{
			// CAISystem (CryAISystem.dll): +0x1e4 byte gates CAISystem::Update (0x31020103),
			// +0x1e0 counts its working passes
			void *sys = getISystem ? getISystem() : 0;
			BYTE *ai = sys ? ((BYTE * (__fastcall *)(void *, void *))VFN(sys, 0x7c))(sys, 0) : 0; // GetAISystem
			if (ai)
				logf("ai: enabled=%u passes=%u", ai[0x1e4], *(DWORD *)(ai + 0x1e0));
		}
		logf("t=%u snap=%u bits=%u upd=%u prio0=%u own=%u(id %u prio %u) | ts=%u ign=%u world=%d ue=%u fail=%u ueIgn=%u my=%u(%u) ids=%u..%u | sent=%u own=%u skip=%u | rx=%u max=%u | gap=%ums | pos=%d,%d,%d",
			now, s.snap, s.snapBits, s.upd, s.upd0, s.updHi, s.plId, s.plPrio,
			s.ts, s.tsIgn, s.tsWorld, s.ue, s.ueFail, s.ueIgn, s.myId, s.ueOwn, s.idMin, s.idMax, s.wr, s.wrOwn, s.skip, s.rx, s.rxMax, s.gap, s.px, s.py, s.pz);
	s.snap = s.upd = s.upd0 = s.updHi = s.ts = s.tsIgn = s.ue = s.ueFail = s.ueIgn = s.ueOwn = s.idMax = s.wr = s.wrOwn = s.skip = s.rx = s.rxMax = s.gap = 0;
	s.idMin = 0xffff;
}

// ---- hooks (thiscall emulated with fastcall: ECX = this, EDX unused) ----
typedef struct { float x, y, z; } Vec3;

static void savePos(void *ent) // IEntity::GetPos(bool bWorldOnly) at vtable +0x04
{
	Vec3 *v = ((Vec3 * (__fastcall *)(void *, void *, int))VFN(ent, 0x04))(ent, 0, 1);
	s.px = (int)(v->x * 10);
	s.py = (int)(v->y * 10);
	s.pz = (int)(v->z * 10);
}

// FIX: on campaign maps a snapshot is bigger than one unreliable packet and its tail never
// reaches the client. The tail is the end of m_lstNetEntities, where the slot's own player
// (spawned last) sits. Sort the list by CNetEntityInfo::GetTimeAffectedPriority
// (m_nPriority * time since last send) so the important entities go first and the rest rotate.
// std::list node (VS 2003): +0 next, +4 prev, +8 CNetEntityInfo
// (+0x10 m_fLastUpdate, +0x24 m_nPriority from the previous Update).
// FIX 10: level entities spawn with netPresence false (XSystemBase.cpp: ed.netPresence = false);
// only players, AI and vehicle-class entities get it, so the server never sends anything else:
// a Gunship flying on the server stays at its start on the clients, pushed barrels never roll
// there. Give net presence to an entity of a class every client has once it moves on the
// server (props pushed by explosions; a remote player's body does not push them there). Never to anything a client may lack: an update for an entity the client did not
// spawn makes CXClient::OnServerMsgUpdateEntity return false and drop the rest of the packet,
// the own player's update included (Birds/Fish/Bugs are ENTITY_DETAIL_ID entities a client can
// suppress, and they move). IEntity vtable: +0x04 GetPos, +0xc4 GetId, +0xd0 GetNetPresence,
// +0xd4 SetNetPresence (SetNetPresence(true) after SetContainer in the vehicle spawn code,
// 0x33071498), +0xe8 GetClassId (WORD, compared with the class ids at 0x33071930).
static int heliClass(WORD c)
{
	return c == 101 || c == 102; // CargoChopper, Gunship
}
// Mods\FarCryCoop\npmask.txt (decimal, optional; for bisecting a crash) turns classes off:
// 1 Paraglider, 2 RigidBody, 4 DestroyableObject, 8 BasicEntity, 16 helicopters. Default 31.
static DWORD g_npMask = 31;
static int syncedClass(WORD c)
{ // ClassRegistry.lua: Paraglider, RigidBody, DestroyableObject, BasicEntity, CargoChopper, Gunship.
  // Helicopters at a normal priority got ~7 updates/s and flew in jerks on the client: hUpd
  // sends them in every snapshot (Boat has a gunship boss, the owner wants them for everyone)
	// + Paraglider: frozen on clients of a listen host
	return ((c == 95) && (g_npMask & 1)) || ((c == 131) && (g_npMask & 2)) || ((c == 133) && (g_npMask & 4)) ||
	       ((c == 146) && (g_npMask & 8)) || (heliClass(c) && (g_npMask & 16));
}
static float g_firstPos[65536][3];
static BYTE g_posSeen[65536];
static void netPresenceIfMoved(void *ent)
{
	WORD id, cls;
	Vec3 *p;
	float *q, dx, dy, dz;
	if (((BYTE(__fastcall *)(void *, void *))VFN(ent, 0xd0))(ent, 0)) // already sent
		return;
	cls = ((WORD(__fastcall *)(void *, void *))VFN(ent, 0xe8))(ent, 0);
	if (!syncedClass(cls))
		return;
	id = ((WORD(__fastcall *)(void *, void *))VFN(ent, 0xc4))(ent, 0);
	// Helicopters: at once, not on the first move. A parked Gunship never moves on the
	// server until its trigger, while the client's copy drifts on its own (measured on
	// Training: up to 38 m off, the server copy did not move), so wait-for-move never fires.
	if (heliClass(cls)) {
		((void(__fastcall *)(void *, void *, int))VFN(ent, 0xd4))(ent, 0, 1);
		logf("net presence on for helicopter %u (class %u)", id, cls);
		return;
	}
	p = ((Vec3 * (__fastcall *)(void *, void *, int))VFN(ent, 0x04))(ent, 0, 1);
	q = g_firstPos[id];
	if (!g_posSeen[id]) {
		g_posSeen[id] = 1;
		q[0] = p->x, q[1] = p->y, q[2] = p->z;
		return;
	}
	dx = p->x - q[0], dy = p->y - q[1], dz = p->z - q[2];
	if (dx * dx + dy * dy + dz * dz < 0.01f)
		return;
	((void(__fastcall *)(void *, void *, int))VFN(ent, 0xd4))(ent, 0, 1);
	logf("net presence on for moved entity %u (class %u)", id, cls);
}

// Mods\FarCryCoop\watchid.txt (see hUe): on the server, the watched entity's place in the snapshot list
static DWORD g_watchId, g_watchSnaps;
#define MAX_NET 4096
static BYTE *v[MAX_NET];    // list nodes in send order
static float k[MAX_NET], lu[MAX_NET]; // sort key, m_fLastUpdate before the snapshot
static int g_n;             // nodes in v, 0 if the list was not sorted
static void sortNetEntities(BYTE *snap)
{
	BYTE *head = *(BYTE **)(snap + 8), *n, *prev; // m_lstNetEntities
	void *timer = *(void **)(snap + 0x18);        // m_pTimer
	float now = ((float(__fastcall *)(void *, void *))VFN(timer, 0x08))(timer, 0), dt, key; // ITimer::GetCurrTime
	int c = 0, i, j;
	g_n = 0;
	for (n = *(BYTE **)head; n != head; n = *(BYTE **)n) {
		if (c == MAX_NET)
			return; // ponytail: list too big, keep engine order and no budget
		if (*(void **)(n + 0xc)) // CNetEntityInfo::m_pEntity
			netPresenceIfMoved(*(void **)(n + 0xc));
		dt = now - *(float *)(n + 0x10);
		if (g_watchId && *(void **)(n + 0xc)) {
			void *we = *(void **)(n + 0xc);
			if (((WORD(__fastcall *)(void *, void *))VFN(we, 0xc4))(we, 0) == g_watchId && !(g_watchSnaps++ % 30))
				logf("watch %u: snapshot list place %d, priority %d, %d ms since sent, net presence %u", g_watchId, c,
				     *(int *)(n + 0x24), (int)(dt * 1000), (DWORD)((BYTE(__fastcall *)(void *, void *))VFN(we, 0xd0))(we, 0));
		}
		v[c] = n;
		k[c++] = (float)*(int *)(n + 0x24) * (dt > 0 ? dt : 0);
	}
	for (i = 1; i < c; i++) { // ponytail: insertion sort, list is nearly sorted after the first frame
		n = v[i];
		key = k[i];
		for (j = i; j > 0 && k[j - 1] < key; j--) {
			v[j] = v[j - 1];
			k[j] = k[j - 1];
		}
		v[j] = n;
		k[j] = key;
	}
	for (prev = head, i = 0; i < c; prev = v[i++]) {
		*(BYTE **)prev = v[i];
		*(BYTE **)(v[i] + 4) = prev;
	}
	*(BYTE **)prev = head;
	*(BYTE **)(head + 4) = prev;
	for (i = 0; i < c; i++)
		lu[i] = *(float *)(v[i] + 0x10);
	g_n = c;
}

// FIX 2: CryNetwork collects the unreliable data of a frame in a CStream with a fixed stack
// buffer: DEFAULT_STREAM_BYTESIZE 1124 bytes = 8992 bits (CryCommon/Stream.h, CStream ctor
// FUN_34502810 in CryNetwork.dll). Writes past it are dropped silently. So hold back entity
// updates past a budget, and give the held-back entities their old m_fLastUpdate back:
// their time-affected priority keeps growing and they move to the front of a later snapshot.
#define SNAP_BUDGET_BITS 8800 // ponytail: margin for TIMESTAMP/CLIENTSTRING/CTP headers (seen 20-100 bits); lower if rx max passes 8992
static int g_inSnap, g_sent, g_full; // in snapshot, updates sent, budget used up
static DWORD g_bits;

static DWORD(__fastcall *oSend)(void *, void *, DWORD, void *, const char *, DWORD);
static DWORD __fastcall hSend(void *slot, void *edx, DWORD msg, void *stm, const char *name, DWORD withSize)
{ // CXServerSlot::SendUnreliableMsg(XSERVERMSG, CStream&, const char*, bool), returns bits sent
	DWORD bits;
	if (g_inSnap && (BYTE)msg == 0 && g_n) { // XSERVERMSG_UPDATEENTITY from our sorted snapshot
		bits = *(DWORD *)((BYTE *)stm + 0x470) + 8; // payload + message id
		if (g_full || g_bits + bits > SNAP_BUDGET_BITS) { // strict prefix: list order = send order
			g_full = 1;
			s.skip++;
			return 0;
		}
		g_bits += bits;
		g_sent++;
	}
	return oSend(slot, edx, msg, stm, name, withSize);
}

static void restoreHeldBack(void)
{
	int i, tried = 0;
	for (i = 0; i < g_n; i++)
		if (*(float *)(v[i] + 0x10) != lu[i] && ++tried > g_sent) // Reset() ran, but nothing was sent
			*(float *)(v[i] + 0x10) = lu[i];
}

static void(__fastcall *oSnap)(void *, void *);
static void __fastcall hSnap(void *self, void *edx)
{
	g_snapTick = GetTickCount();
	sortNetEntities((BYTE *)self);
	g_inSnap = 1;
	g_sent = g_full = 0;
	g_bits = 0;
	oSnap(self, edx);
	g_inSnap = 0;
	gap();
	if (g_n)
		restoreHeldBack();
	s.snap++;
	s.snapBits = ((DWORD *)self)[1]; // m_nLastSnapshotBitSize
	tick();
}

static void(__fastcall *oUpd)(void *, void *, Vec3);
static void __fastcall hUpd(void *self, void *edx, Vec3 viewer)
{
	DWORD prio;
	void **ent;
	oUpd(self, edx, viewer);
	ent = *(void ***)((BYTE *)self + 4); // m_pEntity
	if (ent && heliClass(((WORD(__fastcall *)(void *, void *))VFN(ent, 0xe8))(ent, 0)))
		*(DWORD *)((BYTE *)self + 0x1c) = 500000; // every snapshot, still below the slot's own player
	prio = *(DWORD *)((BYTE *)self + 0x1c); // m_nPriority
	s.upd++;
	if (!prio)
		s.upd0++;
	if (prio >= 1000000) {
		s.updHi++;
		s.plPrio = prio;
		s.plId = 0;
		if (ent) {
			s.plId = ((WORD(__fastcall *)(void *, void *))VFN(ent, 0xc4))(ent, 0); // IEntity::GetId
			savePos(ent);
		}
	}
}

static BYTE(__fastcall *oWr)(void *, void *, void *, void *);
static BYTE __fastcall hWr(void *self, void *edx, void *server, void *stm)
{
	s.wr++;
	if (*(DWORD *)((BYTE *)self + 0x1c) >= 1000000) // m_nPriority: slot's own player
		s.wrOwn++;
	return oWr(self, edx, server, stm);
}

static BYTE(__fastcall *oRx)(void *, void *, void *);
static BYTE __fastcall hRx(void *self, void *edx, void *stm)
{ // CXClient::ParseIncomingStream(CStream&): size of every packet that reaches the game
	DWORD bits = *(DWORD *)((BYTE *)stm + 0x470);
	s.rx++;
	if (bits > s.rxMax)
		s.rxMax = bits;
	return oRx(self, edx, stm);
}

static BYTE(__fastcall *oTs)(void *, void *, void *);
static BYTE __fastcall hTs(void *self, void *edx, void *stm)
{
	BYTE r = oTs(self, edx, stm);
	s.ts++;
	gap();
	if (*((BYTE *)self + 0x14)) // m_bIgnoreSnapshot
		s.tsIgn++;
	s.tsWorld = *(int *)((BYTE *)self + 0x10); // m_iPhysicalWorldTime
	tick();
	return r;
}

static BYTE(__fastcall *oUe)(void *, void *, void *);
static DWORD g_ueId, g_ueClass, g_inUe; // the entity update being parsed (for hPhysErr)
// Mods\FarCryCoop\watchid.txt (decimal, optional; for desync hunting): on a client, log the updates
// of that one entity and whether its physics state was read, with its position after the update
static DWORD g_watchUe, g_watchPh;
static BYTE __fastcall hUe(void *self, void *edx, void *stm)
{
	DWORD *rd = (DWORD *)((BYTE *)stm + 0x474), at = *rd, id = 0; // CStream read position
	void *game = *(void **)((BYTE *)self + 0x44), *bs, *sys, *ent;  // m_pGame
	BYTE r;
	// peek the entity id the same way the original does, then rewind the stream
	bs = ((void *(__fastcall *)(void *, void *))VFN(game, 0x104))(game, 0); // GetIBitStream
	((BYTE(__fastcall *)(void *, void *, void *, DWORD *, int))VFN(bs, 0x10))(bs, 0, stm, &id, 4); // ReadBitStream(stm, id, eEntityId)
	*rd = at;
	if ((WORD)id < s.idMin)
		s.idMin = (WORD)id;
	if ((WORD)id > s.idMax)
		s.idMax = (WORD)id;
	g_ueId = (WORD)id;
	sys = *(void **)((BYTE *)self + 0x4c);
	ent = ((void *(__fastcall *)(void *, void *, int))VFN(sys, 0x58))(sys, 0, (WORD)id);
	g_ueClass = ent ? ((WORD(__fastcall *)(void *, void *))VFN(ent, 0xe8))(ent, 0) : 0xffff;
	g_inUe = 1;
	r = oUe(self, edx, stm);
	g_inUe = 0;
	if (g_watchId && (WORD)id == g_watchId && ent) {
		g_watchUe++;
		if (g_watchUe <= 5 || !(g_watchUe % 50)) {
			Vec3 *p = ((Vec3 * (__fastcall *)(void *, void *, int))VFN(ent, 0x04))(ent, 0, 1);
			logf("watch %u: update %u, physics states read %u, now at %d,%d,%d", g_watchId, g_watchUe, g_watchPh,
			     (int)(p->x * 100), (int)(p->y * 100), (int)(p->z * 100));
		}
	}
	s.ue++;
	s.myId = *(WORD *)((BYTE *)self + 0xc); // m_wPlayerID
	if ((WORD)id == s.myId) {
		s.ueOwn++;
		sys = *(void **)((BYTE *)self + 0x4c); // m_pISystem (IXSystem)
		ent = ((void *(__fastcall *)(void *, void *, int))VFN(sys, 0x58))(sys, 0, (WORD)id); // GetEntity
		if (ent)
			savePos(ent);
	}
	if (*((BYTE *)self + 0x14))
		s.ueIgn++;
	if (!r) {
		s.ueFail++;
		if (s.ueFail <= 3)
			logf("UpdateEntity returned false: rest of this packet is dropped");
	}
	return r;
}

// FIX 3: CMovieUser::BeginCutScene / EndCutScene (GameMovieUser.cpp) call
// GetISystem()->GetIInput()->GetIKeyboard()->ClearKeyState(). The dedicated server has no
// input, so the first cutscene (e.g. in Training) crashes it with a NULL read at 0x330cfe4a.
// The server shows no cutscene, so on a server without input both callbacks are skipped
// (in pairs, so the cutscene counter at +0x0c stays consistent).
static int noInput(void)
{
	void *sys = getISystem();
	return !((void *(__fastcall *)(void *, void *))VFN(sys, 0x58))(sys, 0); // ISystem::GetIInput
}

static void(__fastcall *oBeginCut)(void *, void *, DWORD, DWORD);
static void __fastcall hBeginCut(void *self, void *edx, DWORD flags, DWORD resetFx)
{
	if (noInput())
		return;
	oBeginCut(self, edx, flags, resetFx);
}

static void(__fastcall *oEndCut)(void *, void *);
static void __fastcall hEndCut(void *self, void *edx)
{
	if (noInput())
		return;
	oEndCut(self, edx);
}

// FIX 4: the cutscene sound track in CryMovie (key handler 0x3401a396) loads its sound with
// GetISystem()->GetISoundSystem()->LoadSound(...); the dedicated server has no sound system,
// so it crashes with a NULL read at 0x3401a4eb. Skip only the sound key; the sequence itself
// (entity animation, events that drive the mission) keeps running on the server.
static void(__fastcall *oSoundKey)(void *, void *, void *, DWORD, DWORD, void *, void *);
static void __fastcall hSoundKey(void *self, void *edx, void *a, DWORD b, DWORD c, void *key, void *anim)
{ // thiscall with 5 arguments, RET 0x14
	void *sys = getISystem();
	if (!((void *(__fastcall *)(void *, void *))VFN(sys, 0x6c))(sys, 0)) // ISystem::GetISoundSystem
		return;
	oSoundKey(self, edx, a, b, c, key, anim);
}

// FIX 7: areas for remote players. CPlayer::Update runs m_XAreaMgr.UpdatePlayer only for the
// machine's own player (XPlayer.cpp "areas are only used for the local player"), so on the
// dedicated server no AreaTrigger ever fires and missions stall (e.g. the sleeping village
// on Training). The `je` at 0x330ae17e skips that block when bMyPlayer ([ebp-0x0e]) is 0;
// it now jumps here. Own player: the original block. Others on the server: only the area
// update (not UpdateAutoCenter/UpdateCamera), skipping AI (m_bIsAI +0x3bc). Each player has
// its own CXAreaUser (+0x674, m_pEntity at +0x690), so enter/leave is tracked per player.
// Only in a process that hosts the game (dedicated server, or a listen host that sent a snapshot
// in the last 2 s): on a pure client, other players must not switch its music or EAX areas.
static BYTE *g_areaBlock, *g_areaSkip; // 0x330ae184 (own player's block), 0x330ae218 (after it)
static void(__fastcall *areaUpdatePlayer)(void *, void *, void *); // CXAreaMgr::UpdatePlayer 0x330d3ee8
static void __cdecl remoteAreas(BYTE *player)
{
	static int logged;
	if (!hosting() || player[0x3bc]) // m_bIsAI
		return;
	*(void **)(player + 0x690) = *(void **)(player + 4); // m_AreaUser.SetEntity(m_pEntity)
	areaUpdatePlayer(*(BYTE **)(player + 0x268) + 0x3ac, 0, player + 0x674); // m_pGame->m_XAreaMgr
	if (!logged++)
		logf("areas: first update for remote player %x", (DWORD)player);
}

static __declspec(naked) void hArea(void)
{
	__asm {
		cmp byte ptr [ebp - 0x0e], 0 // bMyPlayer
		jne mine
		pushad
		push ebx                     // this (CPlayer)
		call remoteAreas
		add esp, 4
		popad
		jmp dword ptr [g_areaSkip]
	mine:
		jmp dword ptr [g_areaBlock]
	}
}

static DWORD g_warns;
static void __cdecl logWarn(const char *fmt, va_list va)
{ // log only the raw format: wvsprintfA has no %f, so formatting float arguments could
  // shift the va_list and make a later %s read a garbage pointer
	char buf[300];
	int i;
	if (++g_warns > 500) // ponytail: hard cap so a spamming warning cannot fill the disk
		return;
	for (i = 0; i < 299 && fmt[i]; i++)
		buf[i] = fmt[i];
	buf[i] = 0;
	logf("warn: %s", buf);
}

static void *oWarn;
static __declspec(naked) void hWarn(void)
{
	__asm {
		lea eax, [esp + 8]      // va_list after fmt
		push eax
		push dword ptr [esp + 8] // fmt (shifted by the push above)
		call logWarn
		add esp, 8
		jmp dword ptr [oWarn]
	}
}

// ---- inline hook: copy whole prologue instructions to a trampoline, jump to the hook ----
static int hook(BYTE *p, int len, const BYTE *expect, void *fn, void **orig, const char *name)
{
	BYTE *t;
	DWORD old;
	int i;
	for (i = 0; i < len; i++) // B8 imm32 prologues: only the opcode is checked, imm32 may be relocated
		if (expect[i] != 0xff && p[i] != expect[i]) {
			logf("SKIP %s: unexpected byte %u at +%d", name, p[i], i);
			return 0;
		}
	t = (BYTE *)VirtualAlloc(0, 32, 0x3000, 0x40); // MEM_COMMIT|MEM_RESERVE, PAGE_EXECUTE_READWRITE
	for (i = 0; i < len; i++)
		t[i] = p[i];
	t[len] = 0xe9;
	*(DWORD *)(t + len + 1) = (DWORD)(p + len) - (DWORD)(t + len + 5);
	*orig = t;
	VirtualProtect(p, len, 0x40, &old);
	p[0] = 0xe9;
	*(DWORD *)(p + 1) = (DWORD)fn - (DWORD)(p + 5);
	for (i = 5; i < len; i++)
		p[i] = 0x90;
	VirtualProtect(p, len, old, &old);
	FlushInstructionCache(GetCurrentProcess(), p, len);
	logf("hooked %s at %x", name, (DWORD)p);
	return 1;
}

// FIX 11: CryInput builds its key table (DirectInput scan code -> character, plain/Shift/Ctrl/
// AltGr; 0x33509c40, called from 0x3350a2b3) with MapVirtualKeyExA + ToAsciiEx on
// GetKeyboardLayout(0), the layout of the moment. With the Russian layout the letter keys
// became Cyrillic: the bindings ("w", "c", ...) stopped matching and the console took no
// Latin, and the bindings read from game.cfg at startup were dropped (empty key settings).
// So the game has to see the US layout before CryInput initialises: user32!GetKeyboardLayout
// itself is hooked first thing in the worker, long before CrySystem loads CryInput, and returns
// the US layout (loaded, not activated: Windows keeps the layout the player chose). Only this
// game process is affected; typed text (WM_CHAR) still follows the real layout.
static HANDLE g_usLayout;
static HANDLE __stdcall usLayout(DWORD thread)
{
	(void)thread;
	return g_usLayout;
}

static int hook(BYTE *p, int len, const BYTE *expect, void *fn, void **orig, const char *name);
static void keyboardUS(void)
{
	static const BYTE gkl[] = {0x8b, 0xff, 0x55, 0x8b, 0xec}; // mov edi,edi; push ebp; mov ebp,esp
	BYTE *p = (BYTE *)GetKeyboardLayout, *in;
	void *unused; // usLayout never calls the original
	g_usLayout = LoadKeyboardLayoutA("00000409", 0x80); // KLF_NOTELLSHELL, no KLF_ACTIVATE
	if (!g_usLayout) {
		logf("keyboard: US layout not available, layout not fixed");
		return;
	}
	if (!hook(p, 5, gkl, usLayout, &unused, "user32!GetKeyboardLayout")) {
		logf("keyboard: GetKeyboardLayout starts %x %x %x %x %x, layout not fixed", p[0], p[1], p[2], p[3], p[4]);
		return;
	}
	in = (BYTE *)GetModuleHandleA("CryInput.dll");
	if (in && *(DWORD *)(in + *(DWORD *)(in + 0x3c) + 8) == CRYINPUT_TIMESTAMP) {
		((void(__cdecl *)(void))(in + (0x33509c40 - CRYINPUT_BASE)))(); // already up: rebuild its table
		logf("keyboard: CryInput was already up, key table rebuilt (bindings may need a restart)");
	}
	logf("keyboard: the game uses the US layout");
}

// Steam join (FarCryCoopSteam.exe): when the player clicks Join in the Steam friends list, the
// bridge writes the console line to run into Mods\FarCryCoop\join.txt. It runs on the main
// thread: IGame::Update (CXGame vtable 0x330fd9a0 +0x04 = 0x330c08e6, called every frame, menu
// included) is wrapped and polls the file twice a second, after the frame. Console:
// ISystem::GetIConsole +0x60, IConsole::ExecuteString +0x80 (CXConsole vtable 0x36571c58;
// +0x84 is Exit, which shows "No comments from application" and quits the game).
// The launcher writes join_<pid>.txt for the one game it started: with two games on one PC a
// listen host with no client yet sends no snapshots, so hosting() was 0 and the host's game took
// the client's "connect" line from the shared join.txt and timed out connecting to itself.
// FIX 13: AI jumps. CXPuppetProxy starts the jump animation itself (C++, not from Lua) and the jump
// happens in OnAnimationEvent: JUMP_TAKEOFF (0xffff) at the take-off frame applies the physics jump
// (Action iJump=1), JUMP_LAND (0xff00) at the land frame ends it. Nothing renders on the server,
// and an AI the host does not look at is not animated either: no event ever arrives and the AI
// "jumps" by walking. After the proxy registered both events (0x330ba317, in the AI movement
// update of CXPuppetProxy; ebx = proxy, [ebp-0x24] = animation, [ebp-0x60] = take-off frame,
// [ebp-0x14] = land frame, proxy+0x508 = jump duration) the jump is also timed here: take-off
// 0.15 s after its frame (a real event comes first when the animation does run: m_bInJump,
// proxy+0x4c8, is already set, then nothing is sent), landing one jump duration later, then
// OnEndAnimation. The sink is the proxy's ICharInstanceSink (proxy+4): vtable +4 OnAnimationEvent,
// +8 OnEndAnimation.
#define MAX_JUMPS 16
static struct {
	BYTE *proxy;
	void *vt; // the sink's vtable when registered (an entity freed since then has another)
	char anim[64];
	DWORD tTake, tLand, tEnd;
	int state; // 0 waiting for take-off, 1 in the air, 2 landed
} g_jump[MAX_JUMPS];
static DWORD f2ms(float f) // no CRT: __ftol3 is not linked
{
	static const float k = 1000.f;
	int r;
	__asm {
		fld f
		fmul k
		fistp r
	}
	return (DWORD)r;
}
static void *oJump;
static void __cdecl jumpStarted(BYTE *proxy, const char *anim, int takeFrame, int landFrame)
{
	static int logged;
	DWORD now = GetTickCount(), dur = 0;
	int i, n;
	float d = *(float *)(proxy + 0x508);
	if (!hosting() || IsBadReadPtr(anim, 2))
		return;
	dur = (d > 0.05f && d < 10.f) ? f2ms(d) : (DWORD)((landFrame - takeFrame) * 1000 / 30);
	for (i = 0; i < MAX_JUMPS; i++) // a free slot, or one left over from this proxy
		if (!g_jump[i].proxy || g_jump[i].proxy == proxy || g_jump[i].tEnd + 5000 < now)
			break;
	if (i == MAX_JUMPS)
		return;
	g_jump[i].proxy = proxy;
	g_jump[i].vt = *(void **)(proxy + 4);
	for (n = 0; n < 63 && anim[n]; n++)
		g_jump[i].anim[n] = anim[n];
	g_jump[i].anim[n] = 0;
	g_jump[i].tTake = now + (takeFrame > 0 ? takeFrame * 1000 / 30 : 0) + 150;
	g_jump[i].tLand = g_jump[i].tTake + dur;
	g_jump[i].tEnd = g_jump[i].tLand + 300;
	g_jump[i].state = 0;
	if (logged++ < 5)
		logf("ai jump: %s take-off in %u ms, lands %u ms later", g_jump[i].anim, g_jump[i].tTake - now, dur);
}
static __declspec(naked) void hJump(void)
{
	__asm {
		pushad
		push dword ptr [ebp - 0x14]
		push dword ptr [ebp - 0x60]
		push dword ptr [ebp - 0x24]
		push ebx
		call jumpStarted
		add esp, 16
		popad
		jmp dword ptr [oJump]
	}
}
static void jumpTick(void)
{
	DWORD now;
	int i;
	if (!hosting())
		return;
	now = GetTickCount();
	for (i = 0; i < MAX_JUMPS; i++) {
		BYTE *sink;
		if (!g_jump[i].proxy)
			continue;
		sink = g_jump[i].proxy + 4;
		if (IsBadReadPtr(sink, 4) || *(void **)sink != g_jump[i].vt) { // proxy gone (level change, entity removed)
			g_jump[i].proxy = 0;
			continue;
		}
		if (g_jump[i].state == 0 && (int)(now - g_jump[i].tTake) >= 0) {
			g_jump[i].state = 1;
			if (g_jump[i].proxy[0x4c8]) { // a real animation event came first
				g_jump[i].state = 3;
			} else
				((void(__fastcall *)(void *, void *, const char *, DWORD, DWORD))VFN(sink, 4))(sink, 0, g_jump[i].anim, 0xffff, 0xffff);
		} else if (g_jump[i].state == 1 && (int)(now - g_jump[i].tLand) >= 0) {
			g_jump[i].state = 2;
			((void(__fastcall *)(void *, void *, const char *, DWORD, DWORD))VFN(sink, 4))(sink, 0, g_jump[i].anim, 0xff00, 0xff00);
		} else if (g_jump[i].state == 2 && (int)(now - g_jump[i].tEnd) >= 0) {
			g_jump[i].proxy = 0;
			((void(__fastcall *)(void *, void *, const char *))VFN(sink, 8))(sink, 0, g_jump[i].anim);
		} else if (g_jump[i].state == 3 && (int)(now - g_jump[i].tEnd) >= 0)
			g_jump[i].proxy = 0;
	}
}

static char g_join[600], g_joinOwn[600]; // Mods\FarCryCoop\join.txt, join_<pid>.txt
static BYTE(__fastcall *oGameUpdate)(void *, void *);
static DWORD g_joinTick;
static int g_coop; // this game ran a CoopMap / CoopLoad / Game:Connect line (see the baked physics states)
static int g_ownsServer; // this game ran a CoopMap / CoopLoad line: it hosts, the shared join.txt is not its
static int hasText(const char *s, const char *t)
{
	int i, j;
	for (i = 0; s[i]; i++) {
		for (j = 0; t[j] && s[i + j] == t[j]; j++)
			;
		if (!t[j])
			return 1;
	}
	return 0;
}
static void runJoin(const char *file)
{
	static char cmd[4096]; // a console line from join_<pid>.txt (test scripts send long Lua lines); static: no __chkstk without the CRT, main thread only
	DWORD n = 0;
	void *sys, *con;
	HANDLE f = CreateFileA(file, 0x80000000, 0, 0, 3, 0x80, 0); // GENERIC_READ, OPEN_EXISTING
	if (f == (HANDLE)-1)
		return;
	ReadFile(f, cmd, sizeof cmd - 1, &n, 0);
	CloseHandle(f);
	DeleteFileA(file);
	while (n && (cmd[n - 1] == '\r' || cmd[n - 1] == '\n'))
		n--;
	cmd[n] = 0;
	if (hasText(cmd, "CoopMap(") || hasText(cmd, "CoopLoad("))
		g_ownsServer = 1;
	if (g_ownsServer || hasText(cmd, "Game:Connect("))
		g_coop = 1;
	sys = getISystem();
	con = sys ? ((void *(__fastcall *)(void *, void *))VFN(sys, 0x60))(sys, 0) : 0;
	logf("join: %s", cmd);
	if (con && n)
		((void(__fastcall *)(void *, void *, const char *, int, int))VFN(con, 0x80))(con, 0, cmd, 0, 1);
	logf("join: done");
}
// A player who joins after a movie sequence started (Dam: "heli" at t=0.7, before any client is
// in) never got its SEQ, so what it animates stayed where the level put it. The server sends the
// joiner each sequence of the map with the time since its start (SEQAT, COOP ClientStuff); Lua
// plays it and asks here, in Mods\FarCryCoop\seek_<pid>.txt ("<ms> <name>" lines), to move it to
// that time: Lua's Movie has no such call, IMovieSystem::SetPlayingTime (SDK IMovieSystem.h) does.
// Past its end the movie system stops it on the next update and leaves it at its end. A cutscene
// (CUT_SCENE) goes to its end at once: it does not start for a player who joins in its middle.
// ISystem::GetIMovieSystem +0x78; IMovieSystem: FindSequence +0x28, IsPlaying +0x54,
// GetPlayingTime +0x98, SetPlayingTime +0x9c; IAnimSequence: GetName +0x08, GetFlags +0x10
// (slot 0 is IRefCountBase's virtual destructor). Lua learns the pid from "#COOP_AsiPid=<pid>".
// The same file takes "use": press the use key on this client (harness scenarios: Lua cannot).
// CXClient::TriggerUse (0x3307ead1, thiscall (float, XActivationEvent), ret 8: push 0Ah, add ecx 60h,
// call AddAction) adds ACTION_USE to the next command for the server, as the F key does. CXGame's
// m_pClient is at +0x34 (Game:Connect, 0x33044222: mov ecx,[m_pGame+34h] before XConnect).
static char g_seek[600];
static int g_pidSent;
static void pressUse(BYTE *game)
{
	void *client = game ? *(void **)(game + 0x34) : 0;
	if (!client) {
		logf("use: no client");
		return;
	}
	((void(__fastcall *)(void *, void *, float, int))CG(0x3307ead1))(client, 0, 1.0f, 0);
	logf("use: pressed");
}
static void seekLine(BYTE *game, char *s)
{
	void *sys = getISystem(), *mov, *seq;
	DWORD ms = 0, flags;
	float t, was;
	if (s[0] == 'u' && s[1] == 's' && s[2] == 'e' && !s[3]) {
		pressUse(game);
		return;
	}
	while (*s >= '0' && *s <= '9')
		ms = ms * 10 + (*s++ - '0');
	if (*s++ != ' ' || !*s)
		return;
	mov = sys ? ((void *(__fastcall *)(void *, void *))VFN(sys, 0x78))(sys, 0) : 0;
	seq = mov ? ((void *(__fastcall *)(void *, void *, const char *))VFN(mov, 0x28))(mov, 0, s) : 0;
	if (!seq) {
		logf("seek: no sequence %s", s);
		return;
	}
	flags = ((DWORD(__fastcall *)(void *, void *))VFN(seq, 0x10))(seq, 0);
	t = (flags & 0x008) ? 1000000.0f : (int)ms / 1000.0f; // CUT_SCENE: to its end; int: no CRT helper for unsigned
	was = ((float(__fastcall *)(void *, void *, void *))VFN(mov, 0x98))(mov, 0, seq);
	((BYTE(__fastcall *)(void *, void *, void *, float))VFN(mov, 0x9c))(mov, 0, seq, t);
	logf("seek: %s (%s) flags %x playing %u: %u ms -> %u ms", s, ((const char *(__fastcall *)(void *, void *))VFN(seq, 0x08))(seq, 0),
	     flags, (DWORD)((BYTE(__fastcall *)(void *, void *, void *))VFN(mov, 0x54))(mov, 0, seq), was < 0 ? 0 : f2ms(was), f2ms(t));
}
static void seekTick(BYTE *game)
{
	static char buf[2048]; // static: no __chkstk without the CRT, main thread only
	DWORD n = 0, i, from = 0;
	HANDLE f;
	if (!g_pidSent) { // the console runs "#..." as Lua: tell the scripts which file is ours
		void *sys = getISystem(), *con = sys ? ((void *(__fastcall *)(void *, void *))VFN(sys, 0x60))(sys, 0) : 0;
		void *args[1];
		char line[40];
		if (!con)
			return;
		args[0] = (void *)GetCurrentProcessId();
		wvsprintfA(line, "#COOP_AsiPid=%u", (va_list)args);
		((void(__fastcall *)(void *, void *, const char *, int, int))VFN(con, 0x80))(con, 0, line, 0, 1);
		g_pidSent = 1;
	}
	f = CreateFileA(g_seek, 0x80000000, 0, 0, 3, 0x80, 0); // GENERIC_READ, OPEN_EXISTING
	if (f == (HANDLE)-1)
		return;
	ReadFile(f, buf, sizeof buf - 1, &n, 0);
	CloseHandle(f);
	DeleteFileA(g_seek);
	buf[n] = 0;
	for (i = 0; i <= n; i++)
		if (buf[i] == '\n' || buf[i] == '\r' || !buf[i]) {
			buf[i] = 0;
			if (i > from)
				seekLine(game, buf + from);
			from = i + 1;
		}
}

static BYTE __fastcall hGameUpdate(void *game, void *edx)
{
	BYTE r = oGameUpdate(game, edx); // after the frame, as the console runs typed lines
	jumpTick();
	seekTick((BYTE *)game);
	if (GetTickCount() - g_joinTick > 500) {
		g_joinTick = GetTickCount();
		runJoin(g_joinOwn);
		if (!hosting() && !g_ownsServer) // a host leaves the shared file to the other window (bridge -loop)
			runJoin(g_join);
	}
	return r;
}

// Crashes leave only a broken stack in log.txt: log where access violations happen (first ones).
static int g_faults;
static long __stdcall onFault(void **info) // EXCEPTION_POINTERS
{
	DWORD *rec = (DWORD *)info[0], *ctx = (DWORD *)info[1];
	if (rec[0] == 0xc0000005 && g_faults++ < 5) // access violations only (C++ throws are normal); CONTEXT.Esp at +0xc4
		{
		logf("exception %x at %x (%u %x) esp %x [%x %x %x %x]", rec[0], rec[3], rec[5], rec[6], ctx[0xc4 / 4],
			((DWORD *)ctx[0xc4 / 4])[0], ((DWORD *)ctx[0xc4 / 4])[1], ((DWORD *)ctx[0xc4 / 4])[2], ((DWORD *)ctx[0xc4 / 4])[3]);
		{ // the words of the stack that look like code in the game's DLLs (0x30000000-0x38000000): who called
			DWORD *sp = (DWORD *)ctx[0xc4 / 4], hit[24];
			int i, n = 0;
			for (i = 0; i < 400 && n < 24; i++)
				if (sp[i] >= 0x30000000 && sp[i] < 0x38000000)
					hit[n++] = sp[i];
			for (i = 0; i < n; i += 6)
				logf("  code on the stack: %x %x %x %x %x %x", hit[i], i + 1 < n ? hit[i + 1] : 0, i + 2 < n ? hit[i + 2] : 0,
				     i + 3 < n ? hit[i + 3] : 0, i + 4 < n ? hit[i + 4] : 0, i + 5 < n ? hit[i + 5] : 0);
		}
		}
	return 0; // EXCEPTION_CONTINUE_SEARCH
}
static void steamJoin(void)
{
	void *sys = getISystem(), *game = 0, **slot;
	DWORD old;
	int i;
	for (i = 0; i < 1200 && !(game = sys ? ((void *(__fastcall *)(void *, void *))VFN(sys, 0x4c))(sys, 0) : 0); i++) { // GetIGame
		Sleep(100);
		sys = getISystem();
	}
	if (!game) {
		logf("steam: no IGame in 120 s, Steam join off");
		return;
	}
	slot = &(*(void ***)game)[1]; // IGame::Update
	oGameUpdate = (BYTE(__fastcall *)(void *, void *))*slot;
	VirtualProtect(slot, 4, 0x04, &old); // PAGE_READWRITE
	*slot = (void *)hGameUpdate;
	VirtualProtect(slot, 4, old, &old);
	logf("steam: polling %s", g_join);
}

// CryPhysics.dll's error reporter (FUN_350052d0, RVA 0x52d0, printf-like, cdecl): it shows the
// "CryEngine Error" window and ends the game. The hook logs the format, two arguments and the
// return addresses (ebp chain) first, to find who read a broken physics stream
// ("ReadPacked i==%i" with i > 16 means the stream is out of step).
static BYTE *g_phys;
static void(__cdecl *oPhysErr)(const char *, int, int, int);
// CryPhysics RVA 0x9c9b0 is the rigid body's SetStateFromSnapshot(CStream &stm, int flags) (thiscall,
// ret 8; it ends in the ReadPacked reader FUN_3509b880). The hook remembers which physical entity is
// being read, so the error log can name it: GetForeignData is IPhysicalEntity vtable slot 7, the
// IEntity's GetId/GetClassId/GetPos are the slots used in netPresenceIfMoved.
static void *g_phSelf;
static DWORD g_phRet, g_phFlags; // who called it, and the flags
// FUN_350c2fd0 (RVA 0xc2fd0..0xc309e) is SetStateFromSnapshotTxt: it turns a text state, baked into a level
// entity, into a CStream and calls SetStateFromSnapshot. On Treehouse and Swamp that text does not match the
// reader ("ReadPacked i==20"), and the engine ends the game. Ignoring the errors only moves the crash on
// (an access violation in the half-read body), so in a co-op game the baked state is not applied at all:
// the object stays where the level file puts it.
static DWORD g_bakedSkipped;
static int(__fastcall *oPhSet)(void *, void *, void *, int);
static int __fastcall hPhSet(void *self, void *edx, void *stm, int flags)
{
	g_phSelf = self;
	g_phRet = ((DWORD *)&stm)[-1]; // the slot below the first stack argument is the return address
	g_phFlags = (DWORD)flags;
	if (g_coop && g_phys && g_phRet >= (DWORD)g_phys + 0xc2fd0 && g_phRet < (DWORD)g_phys + 0xc309e) {
		g_bakedSkipped++;
		if (g_bakedSkipped <= 3 || !(g_bakedSkipped & 255))
			logf("baked physics state skipped (%u so far)", g_bakedSkipped);
		return 0;
	}
	if (g_watchId && g_inUe && g_ueId == g_watchId)
		g_watchPh++;
	return oPhSet(self, edx, stm, flags);
}
static void __cdecl hPhysErr(const char *fmt, int a1, int a2, int a3)
{
	DWORD *fp, ret[10];
	int n = 0;
	__asm mov fp, ebp
	while (n < 10 && (DWORD)fp > 0x10000 && !((DWORD)fp & 3)) {
		ret[n++] = fp[1];
		if (fp[0] <= (DWORD)fp)
			break;
		fp = (DWORD *)fp[0];
	}
	logf("PHYSICS ERROR \"%s\" %d %d; in entity update: %u, entity %u class %u; CryPhysics at %x, CryGame at %x", fmt, a1, a2, g_inUe,
	     g_ueId, g_ueClass, (DWORD)g_phys, (DWORD)g_base);
	if (g_phSelf) {
		void *ent = ((void *(__fastcall *)(void *, void *, int))VFN(g_phSelf, 0x1c))(g_phSelf, 0, 0); // GetForeignData(0)
		if (ent) {
			Vec3 *p = ((Vec3 * (__fastcall *)(void *, void *, int))VFN(ent, 0x04))(ent, 0, 1);
			logf("  physical entity being read: entity %u class %u at %d,%d,%d", ((WORD(__fastcall *)(void *, void *))VFN(ent, 0xc4))(ent, 0),
			     ((WORD(__fastcall *)(void *, void *))VFN(ent, 0xe8))(ent, 0), (int)p->x, (int)p->y, (int)p->z);
		} else
			logf("  physical entity being read: no IEntity (foreign data is null)");
	}
	logf("  SetStateFromSnapshot was called from %x with flags %u", g_phRet, g_phFlags);
	logf("  stack: %x %x %x %x %x %x %x %x %x %x", n > 0 ? ret[0] : 0, n > 1 ? ret[1] : 0, n > 2 ? ret[2] : 0,
	     n > 3 ? ret[3] : 0, n > 4 ? ret[4] : 0, n > 5 ? ret[5] : 0, n > 6 ? ret[6] : 0, n > 7 ? ret[7] : 0,
	     n > 8 ? ret[8] : 0, n > 9 ? ret[9] : 0);
	oPhysErr(fmt, a1, a2, a3);
}

// FIX 12 (issue #2): CrySystem's STLport node allocator (blocks up to 128 bytes: alloc FUN_36505c27(n),
// free FUN_365055c8(p, n), free lists at 0x365888c0) takes no lock, but the main thread is not its only
// user: CrySoundSystem's streaming thread opens sound files through CryPak and builds STLport strings in
// CrySystem too. When both pop or push the same free list at once, one block is handed out twice and a
// free list ends up holding string text ("Poin", "Basi", "Bump"); a later level change dies in the
// allocator. Both functions now run under one critical section; the netlog counts the times a thread
// had to wait, each of them a corruption without it.
#define CRYSYSTEM_TIMESTAMP 0x44b2705bu
static DWORD g_nodeCs[6], g_nodeWaits; // CRITICAL_SECTION (24 bytes)
static void nodeLock(void)
{
	if (TryEnterCriticalSection(g_nodeCs))
		return;
	if (++g_nodeWaits <= 10 || !(g_nodeWaits & 1023))
		logf("node allocator: thread %u waited for another thread (%u times so far)", GetCurrentThreadId(), g_nodeWaits);
	EnterCriticalSection(g_nodeCs);
}
static void *(__cdecl *oNodeAlloc)(DWORD);
static void *__cdecl hNodeAlloc(DWORD n)
{
	void *p;
	nodeLock();
	p = oNodeAlloc(n);
	LeaveCriticalSection(g_nodeCs);
	return p;
}
static void(__cdecl *oNodeFree)(void *, DWORD);
static void __cdecl hNodeFree(void *p, DWORD n)
{
	nodeLock();
	oNodeFree(p, n);
	LeaveCriticalSection(g_nodeCs);
}

static DWORD __stdcall worker(void *unused)
{
	static const BYTE eh[] = {0xb8, 0xff, 0xff, 0xff, 0xff};                // mov eax, imm32 (EH prolog)
	static const BYTE ue[] = {0x55, 0x8b, 0xec, 0x83, 0xec, 0x14};          // push ebp; mov ebp,esp; sub esp,14
	static const BYTE wr[] = {0x55, 0x8b, 0xec, 0x53, 0x56};                // push ebp; mov ebp,esp; push ebx; push esi
	static const BYTE ts[] = {0x55, 0x8b, 0xec, 0x51, 0x51};                // push ebp; mov ebp,esp; push ecx x2
	static const BYTE gw[] = {0x55, 0x8b, 0xec, 0xb8, 0x00, 0x10, 0, 0};    // push ebp; mov ebp,esp; mov eax,1000h
	BYTE *nt;
	int i;
	if (!g_server) // first, before CryInput initialises; the dedicated server has no input
		keyboardUS();
	{
		BYTE *cs;
		for (i = 0; i < 120000 && !(cs = (BYTE *)GetModuleHandleA("CrySystem.dll")); i++)
			Sleep(1);
		if (cs && *(DWORD *)(cs + *(DWORD *)(cs + 0x3c) + 8) == CRYSYSTEM_TIMESTAMP) {
			static const BYTE na[] = {0x8b, 0x54, 0x24, 0x04, 0x8d, 0x4a, 0xff};             // mov edx,[esp+4]; lea ecx,[edx-1]
			static const BYTE nf[] = {0x8b, 0x44, 0x24, 0x08, 0x8b, 0x4c, 0x24, 0x04}; // mov eax,[esp+8]; mov ecx,[esp+4]
			hook(cs + 0x5c27, 7, na, hNodeAlloc, (void **)&oNodeAlloc, "CrySystem node alloc");
			hook(cs + 0x55c8, 8, nf, hNodeFree, (void **)&oNodeFree, "CrySystem node free");
		} else
			logf("CrySystem.dll missing or not the 1.4 build, node allocator not hooked");
	}
	for (i = 0; i < 120000 && !(g_base = (BYTE *)GetModuleHandleA("CryGame.dll")); i++)
		Sleep(1);
	if (!g_base) {
		logf("CryGame.dll not loaded in 120 s, nothing hooked");
		return 0;
	}
	nt = g_base + *(DWORD *)(g_base + 0x3c);
	if (*(DWORD *)(nt + 8) != CRYGAME_TIMESTAMP) {
		logf("CryGame.dll timestamp %x is not 1.4.0.1405, nothing hooked", *(DWORD *)(nt + 8));
		return 0;
	}
	logf("CryGame.dll at %x", (DWORD)g_base);
	g_movie = (BYTE *)GetModuleHandleA("CryMovie.dll");
	if (g_movie && *(DWORD *)(g_movie + *(DWORD *)(g_movie + 0x3c) + 8) == CRYMOVIE_TIMESTAMP) {
		static const BYTE sk[] = {0x55, 0x8b, 0xec, 0x51, 0x8b, 0x45, 0x10}; // push ebp; mov ebp,esp; push ecx; mov eax,[ebp+10]
		hook(g_movie + (0x3401a396 - CRYMOVIE_BASE), 7, sk, hSoundKey, (void **)&oSoundKey, "CryMovie sound track key");
	} else
		logf("CryMovie.dll missing or not the 1.4 build, sound key not hooked");
	getISystem = (void *(__cdecl *)(void))(g_base + (0x330be6e8 - CRYGAME_BASE));
	hook(CG(0x330cfd25), 5, eh, hBeginCut, (void **)&oBeginCut, "CMovieUser::BeginCutScene");
	hook(CG(0x330cfed6), 5, eh, hEndCut, (void **)&oEndCut, "CMovieUser::EndCutScene");
	hook(CG(0x3306faba), 5, eh, hSnap, (void **)&oSnap, "CXSnapshot::BuildAndSendSnapshot");
	hook(CG(0x330bb9b7), 5, eh, hUpd, (void **)&oUpd, "CNetEntityInfo::Update");
	hook(CG(0x330bb82d), 5, wr, hWr, (void **)&oWr, "CNetEntityInfo::Write");
	hook(CG(0x3306c620), 5, eh, hSend, (void **)&oSend, "CXServerSlot::SendUnreliableMsg");
	hook(CG(0x3308354b), 6, ue, hRx, (void **)&oRx, "CXClient::ParseIncomingStream");
	hook(CG(0x33080227), 5, ts, hTs, (void **)&oTs, "CXClient::OnServerMsgTimeStamp");
	hook(CG(0x330816ef), 6, ue, hUe, (void **)&oUe, "CXClient::OnServerMsgUpdateEntity");
	hook(CG(0x3307019e), 8, gw, hWarn, &oWarn, "GameWarning");
	{
		static const BYTE fl[] = {0xd9, 0x05, 0xff, 0xff, 0xff, 0xff}; // fld dword ptr [0x330ee61c] (absolute, relocatable)
		hook(CG(0x330ba317), 6, fl, hJump, &oJump, "CXPuppetProxy jump registered");
	}
	{ // every process: a listen host runs remote players' areas too (remoteAreas checks hosting())
		static const BYTE je[] = {0x0f, 0x84, 0x94, 0x00, 0x00, 0x00}; // je +0x94 (skip area block)
		void *unused; // the trampoline of a relative jump is never called
		g_areaBlock = CG(0x330ae184);
		g_areaSkip = CG(0x330ae218);
		areaUpdatePlayer = (void(__fastcall *)(void *, void *, void *))CG(0x330d3ee8);
		hook(CG(0x330ae17e), 6, je, hArea, &unused, "CPlayer::Update area check");
	}
	{
		static const BYTE pe[] = {0xb8, 0x00, 0x10, 0x00, 0x00}; // mov eax, 1000h (then the stack probe)
		g_phys = (BYTE *)GetModuleHandleA("CryPhysics.dll");
		if (g_phys)
			hook(g_phys + 0x52d0, 5, pe, hPhysErr, (void **)&oPhysErr, "CryPhysics error reporter");
		if (g_phys) {
			static const BYTE ss[] = {0x81, 0xec, 0xd4, 0x00, 0x00, 0x00}; // sub esp, 0D4h
			hook(g_phys + 0x9c9b0, 6, ss, hPhSet, (void **)&oPhSet, "CPhysicalEntity rigid SetStateFromSnapshot");
		}
		else
			logf("CryPhysics.dll not loaded, error reporter not hooked");
	}
	AddVectoredExceptionHandler(1, onFault);
	if (!g_server)
		steamJoin();
	return 0;
}

// Log file: <game>\Mods\FarCryCoop\netlog_<exe>_<pid>.txt (the ASI sits in <game>\Bin32).
BOOL __stdcall DllMain(HANDLE self, DWORD reason, void *reserved)
{
	char path[600], exe[260], *p, *name;
	void *args[2];
	int n, cut = 0;
	if (reason != 1) // DLL_PROCESS_ATTACH
		return 1;
	DisableThreadLibraryCalls(self);
	InitializeCriticalSection(g_nodeCs);
	GetModuleFileNameA(0, exe, sizeof exe);
	for (name = p = exe; *p; p++)
		if (*p == '\\')
			name = p + 1;
	for (p = name; *p; p++)
		if (*p == '.')
			*p = 0;
	g_server = !lstrcmpiA(name, "FarCry_WinSV");
	// FIX 9: FarCry_WinSV.exe sleeps between frames (sv_DedicatedMaxRate 80), and with the
	// default 15.6 ms timer resolution every Sleep lasts a whole tick: the server ran at ~17
	// frames and snapshots a second on 12% of a core (38 with this, measured). Windows 10 2004+
	// keeps the resolution per process, so the server has to ask for it itself.
	if (g_server)
		timeBeginPeriod(1);
	n = (int)GetModuleFileNameA(self, path, 260);
	while (n > 0 && cut < 2) // strip "\FarCryCoopNet.asi" and "\Bin32"
		if (path[--n] == '\\')
			cut++;
	args[0] = name;
	args[1] = (void *)GetCurrentProcessId();
	for (cut = 0; cut < n; cut++) // path still ends at <game>
		g_join[cut] = path[cut];
	wvsprintfA(g_join + n, "\\Mods\\FarCryCoop\\join.txt", 0);
	for (cut = 0; cut < n; cut++)
		g_joinOwn[cut] = path[cut];
	wvsprintfA(g_joinOwn + n, "\\Mods\\FarCryCoop\\join_%u.txt", (va_list)(args + 1));
	for (cut = 0; cut < n; cut++)
		g_seek[cut] = path[cut];
	wvsprintfA(g_seek + n, "\\Mods\\FarCryCoop\\seek_%u.txt", (va_list)(args + 1));
	wvsprintfA(path + n, "\\Mods\\FarCryCoop\\npmask.txt", 0);
	{
		HANDLE f = CreateFileA(path, 0x80000000, 1, 0, 3, 0x80, 0);
		char b[16];
		DWORD got = 0, v = 0;
		if (f != (HANDLE)-1) {
			ReadFile(f, b, sizeof b - 1, &got, 0);
			CloseHandle(f);
			for (cut = 0; cut < (int)got && b[cut] >= '0' && b[cut] <= '9'; cut++)
				v = v * 10 + (b[cut] - '0');
			g_npMask = v;
		}
	}
	wvsprintfA(path + n, "\\Mods\\FarCryCoop\\watchid.txt", 0);
	{
		HANDLE f = CreateFileA(path, 0x80000000, 1, 0, 3, 0x80, 0);
		char b[16];
		DWORD got = 0;
		if (f != (HANDLE)-1) {
			ReadFile(f, b, sizeof b - 1, &got, 0);
			CloseHandle(f);
			for (cut = 0; cut < (int)got && b[cut] >= '0' && b[cut] <= '9'; cut++)
				g_watchId = g_watchId * 10 + (b[cut] - '0');
		}
	}
	wvsprintfA(path + n, "\\Mods\\FarCryCoop\\netlog_%s_%u.txt", (va_list)args);
	g_log = CreateFileA(path, 0x40000000, 1, 0, 2, 0x80, 0); // GENERIC_WRITE, FILE_SHARE_READ, CREATE_ALWAYS
	logf("FarCryCoopNet loaded in %s, net presence mask %u", name, g_npMask);
	CreateThread(0, 0, worker, 0, 0, 0);
	return 1;
}
