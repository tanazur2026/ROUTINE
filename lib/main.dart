import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

const bg = Color(0xFF101318);
const panel = Color(0xFF191E25);
const panel2 = Color(0xFF222933);
const green = Color(0xFF72D6A0);
const muted = Color(0xFF9AA4B2);
const white = Color(0xFFF2F5F7);

String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(DateTime(d.year,d.month,d.day));
String monthKey(DateTime d) => DateFormat('yyyy-MM').format(d);
String arDate(DateTime d) => DateFormat('EEEE، d MMMM yyyy', 'ar').format(d);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  await AppDb.instance.init();
  await ReminderService.instance.init();
  runApp(const RoutineApp());
}

class RoutineApp extends StatelessWidget {
  const RoutineApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'روتين | ROUTINE',
    locale: const Locale('ar'),
    supportedLocales: const [Locale('ar'), Locale('en')],
    localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: green, secondary: green, surface: panel,
        onSurface: white, onPrimary: bg,
      ),
      fontFamily: 'Roboto',
      useMaterial3: true,
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: white, elevation: 0),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: panel, indicatorColor: green.withOpacity(.16),
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: panel2,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      ),
    ),
    home: const MainShell(),
  );
}

class RoutineTask {
  final int? id;
  final String title, description, date, category;
  final String? time;
  final bool done;
  const RoutineTask({this.id, required this.title, this.description='', required this.date,
    this.category='عام', this.time, this.done=false});
  factory RoutineTask.fromMap(Map<String,dynamic> m) => RoutineTask(
    id:m['id'] as int, title:m['title'] as String, description:m['description'] as String? ?? '',
    date:m['date'] as String, category:m['category'] as String? ?? 'عام',
    time:m['time'] as String?, done:(m['done'] as int? ?? 0)==1);
  Map<String,dynamic> toMap() => {'id':id,'title':title,'description':description,'date':date,
    'category':category,'time':time,'done':done?1:0};
}

class AppDb {
  AppDb._();
  static final instance=AppDb._();
  Database? _db;
  Future<void> init() async {
    final path= p.join(await getDatabasesPath(),'routine.db');
    _db=await openDatabase(path,version:1,onCreate:(db,v) async {
      await db.execute('''CREATE TABLE tasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
        date TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'عام', time TEXT, done INTEGER NOT NULL DEFAULT 0
      )''');
    });
  }
  Database get db => _db!;
  Future<List<RoutineTask>> tasksFor(DateTime date) async {
    final rows=await db.query('tasks',where:'date=?',whereArgs:[dayKey(date)],orderBy:"CASE WHEN time IS NULL THEN 1 ELSE 0 END, time ASC, id ASC");
    return rows.map(RoutineTask.fromMap).toList();
  }
  Future<List<RoutineTask>> allTasks() async {
    final rows=await db.query('tasks',orderBy:'date DESC, id DESC');
    return rows.map(RoutineTask.fromMap).toList();
  }
  Future<int> save(RoutineTask t) async {
    if(t.id==null) return db.insert('tasks',t.toMap()..remove('id'));
    return db.update('tasks',t.toMap(),where:'id=?',whereArgs:[t.id]);
  }
  Future<void> delete(int id) async { await db.delete('tasks',where:'id=?',whereArgs:[id]); }
  Future<void> resetMonth(DateTime d) async { await db.delete('tasks',where:'substr(date,1,7)=?',whereArgs:[monthKey(d)]); }
  Future<void> setDone(RoutineTask t,bool value) async {
    await db.update('tasks',{'done':value?1:0},where:'id=?',whereArgs:[t.id]);
  }
}

class ReminderService {
  ReminderService._();
  static final instance=ReminderService._();
  final plugin=FlutterLocalNotificationsPlugin();
  Future<void> init() async {
    tzdata.initializeTimeZones();
    try {
      final local=await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
    } catch (_) { tz.setLocalLocation(tz.local); }
    const android=AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(const InitializationSettings(android:android));
    final androidPlugin=plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestExactAlarmsPermission();
    await reschedule();
  }
  Future<void> reschedule() async {
    final prefs=await SharedPreferences.getInstance();
    final enabled=prefs.getBool('reminders') ?? true;
    await plugin.cancelAll();
    if(!enabled) return;
    final start=prefs.getInt('startHour') ?? 8;
    final end=prefs.getInt('endHour') ?? 22;
    final interval=prefs.getInt('frequency') ?? 1;
    final includeTasks=prefs.getBool('includeTasks') ?? false;
    final now=tz.TZDateTime.now(tz.local);
    int id=1000;
    // Keep a rolling 20-day schedule below Android's practical pending-alarm limits.
    for(int day=0;day<20;day++) {
      final date=DateTime(now.year,now.month,now.day).add(Duration(days:day));
      for(int hour=start;hour<=end;hour+=interval) {
        final scheduled=tz.TZDateTime(tz.local,date.year,date.month,date.day,hour);
        if(!scheduled.isAfter(now)) continue;
        String body='ساعة جديدة، فرصة جديدة لإنجاز مهامك.';
        if(includeTasks) {
          final tasks=await AppDb.instance.tasksFor(date);
          final pending=tasks.where((t)=>!t.done).toList();
          if(pending.isNotEmpty) body='لديك ${pending.length} مهام متبقية. عد إلى روتينك وأكمل ما بدأته.';
          else body='أحسنت! راجع خطتك وحدد خطوتك التالية.';
        }
        await plugin.zonedSchedule(id++, 'حان وقت روتينك', body, scheduled,
          const NotificationDetails(android:AndroidNotificationDetails(
            'routine_hourly','تذكيرات روتين',channelDescription:'تذكيرات دورية لمراجعة مهامك',
            importance:Importance.defaultImportance,priority:Priority.defaultPriority,
          )),
          androidScheduleMode:AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    }
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override State<MainShell> createState()=>_MainShellState();
}
class _MainShellState extends State<MainShell> {
  int tab=0;
  DateTime selected=DateTime.now();
  void refresh()=>setState(()=>selected=selected);
  @override Widget build(BuildContext context) {
    final pages=[
      HomePage(onAdd:()=>_addTask(context,selected,refresh),onDate:(d)=>setState(()=>selected=d),selected:selected),
      CalendarPage(selected:selected,onSelect:(d)=>setState(()=>selected=d),onAdd:()=>_addTask(context,selected,refresh)),
      TasksPage(onChanged:refresh),
      const ProgressPage(),
      const SettingsPage(),
    ];
    return Scaffold(
      body: SafeArea(child:IndexedStack(index:tab,children:pages)),
      bottomNavigationBar:NavigationBar(
        selectedIndex:tab,onDestinationSelected:(i)=>setState(()=>tab=i),
        destinations:const [
          NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'الرئيسية'),
          NavigationDestination(icon:Icon(Icons.calendar_month_outlined),selectedIcon:Icon(Icons.calendar_month),label:'الشهر'),
          NavigationDestination(icon:Icon(Icons.checklist_outlined),selectedIcon:Icon(Icons.checklist),label:'مهامي'),
          NavigationDestination(icon:Icon(Icons.insights_outlined),selectedIcon:Icon(Icons.insights),label:'إنجازاتي'),
          NavigationDestination(icon:Icon(Icons.settings_outlined),selectedIcon:Icon(Icons.settings),label:'الإعدادات'),
        ]),
      floatingActionButton:tab<3?FloatingActionButton(
        backgroundColor:green,foregroundColor:bg,onPressed:()=>_addTask(context,selected,refresh),
        child:const Icon(Icons.add)):null,
    );
  }
}

Future<void> _addTask(BuildContext context,DateTime initial,VoidCallback changed,{RoutineTask? existing}) async {
  final title=TextEditingController(text:existing?.title??'');
  final desc=TextEditingController(text:existing?.description??'');
  DateTime date=DateTime.tryParse(existing?.date??'')??initial;
  TimeOfDay? time=existing?.time==null?null:TimeOfDay(hour:int.parse(existing!.time!.split(':')[0]),minute:int.parse(existing.time!.split(':')[1]));
  String category=existing?.category??'عام';
  bool everyDay=false, weekdays=false;
  await showModalBottomSheet(context:context,isScrollControlled:true,backgroundColor:panel,
    shape:const RoundedRectangleBorder(borderRadius:BorderRadius.vertical(top:Radius.circular(26))),
    builder:(ctx)=>StatefulBuilder(builder:(ctx,setModal)=>Padding(
      padding:EdgeInsets.only(left:20,right:20,top:22,bottom:MediaQuery.of(ctx).viewInsets.bottom+24),
      child:SingleChildScrollView(child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,mainAxisSize:MainAxisSize.min,children:[
        Row(children:[Expanded(child:Text(existing==null?'مهمة جديدة':'تعديل المهمة',style:const TextStyle(fontSize:21,fontWeight:FontWeight.bold))),IconButton(onPressed:()=>Navigator.pop(ctx),icon:const Icon(Icons.close))]),
        const SizedBox(height:14),
        TextField(controller:title, autofocus:true, textDirection:TextDirection.rtl, decoration:const InputDecoration(labelText:'اسم المهمة',hintText:'مثلاً: قراءة 20 صفحة')),
        const SizedBox(height:12),
        TextField(controller:desc,textDirection:TextDirection.rtl,maxLines:2,decoration:const InputDecoration(labelText:'وصف أو ملاحظات (اختياري)')),
        const SizedBox(height:14),
        Row(children:[
          Expanded(child:OutlinedButton.icon(onPressed:()async{final d=await showDatePicker(context:ctx,initialDate:date,firstDate:DateTime(2020),lastDate:DateTime(2100),locale:const Locale('ar'));if(d!=null)setModal(()=>date=d);},icon:const Icon(Icons.calendar_today),label:Text(DateFormat('d MMM yyyy','ar').format(date)))),
          const SizedBox(width:8),
          Expanded(child:OutlinedButton.icon(onPressed:()async{final t=await showTimePicker(context:ctx,initialTime:time??TimeOfDay.now());if(t!=null)setModal(()=>time=t);},icon:const Icon(Icons.access_time),label:Text(time==null?'دون وقت':time!.format(ctx)))),
        ]),
        const SizedBox(height:12),
        DropdownButtonFormField<String>(value:category,decoration:const InputDecoration(labelText:'التصنيف'),items:['عام','عمل','دراسة','صحة','شخصي'].map((e)=>DropdownMenuItem(value:e,child:Text(e))).toList(),onChanged:(v)=>setModal(()=>category=v??'عام')),
        if(existing==null)...[
          const SizedBox(height:12),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('تكرار يومياً خلال الشهر'),value:everyDay,onChanged:(v)=>setModal(()=>everyDay=v),activeColor:green),
          SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('تكرار في أيام الأسبوع نفسها'),subtitle:const Text('ينشئ نسخة في اليوم نفسه من كل أسبوع خلال الشهر'),value:weekdays,onChanged:(v)=>setModal(()=>weekdays=v),activeColor:green),
        ],
        const SizedBox(height:12),
        FilledButton(onPressed:()async{
          if(title.text.trim().isEmpty)return;
          final timeText=time==null?null:'${time!.hour.toString().padLeft(2,'0')}:${time!.minute.toString().padLeft(2,'0')}';
          final dates=<DateTime>[date];
          if(existing==null&&(everyDay||weekdays)){
            final last=DateTime(date.year,date.month+1,0);
            for(int i=1;i<=last.day-date.day;i++){
              final d=date.add(Duration(days:i));
              if(everyDay||(weekdays&&d.weekday==date.weekday))dates.add(d);
            }
          }
          for(final d in dates){
            await AppDb.instance.save(RoutineTask(id:existing?.id,title:title.text.trim(),description:desc.text.trim(),date:dayKey(d),category:category,time:timeText,done:existing?.done??false));
          }
          if(ctx.mounted)Navigator.pop(ctx);
          changed();
        },child:Text(existing==null?'حفظ المهمة':'حفظ التعديلات')),
      ])),
    )));
}

class HomePage extends StatefulWidget {
  final VoidCallback onAdd; final ValueChanged<DateTime> onDate; final DateTime selected;
  const HomePage({super.key,required this.onAdd,required this.onDate,required this.selected});
  @override State<HomePage> createState()=>_HomePageState();
}
class _HomePageState extends State<HomePage> {
  List<RoutineTask> tasks=[];
  @override void initState(){super.initState();load();}
  @override void didUpdateWidget(covariant HomePage old){super.didUpdateWidget(old);if(dayKey(old.selected)!=dayKey(widget.selected))load();}
  Future<void> load()async{tasks=await AppDb.instance.tasksFor(widget.selected);if(mounted)setState((){});}
  @override Widget build(BuildContext context){
    final done=tasks.where((t)=>t.done).length;
    final pct=tasks.isEmpty?0.0:done/tasks.length;
    final now=DateTime.now();
    return RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.fromLTRB(20,18,20,100),children:[
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(_greeting(),style:const TextStyle(color:muted,fontSize:14)),
          const SizedBox(height:5),const Text('أهلاً بك في روتين',style:TextStyle(fontSize:25,fontWeight:FontWeight.bold,color:white)),
        ]),
        Container(width:46,height:46,decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(16)),child:const Icon(Icons.auto_awesome,color:green)),
      ]),
      const SizedBox(height:22),
      Text(arDate(now),style:const TextStyle(color:muted,fontSize:13)),
      const SizedBox(height:16),
      Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF233C34),Color(0xFF1A2928)],begin:Alignment.topRight,end:Alignment.bottomLeft),borderRadius:BorderRadius.circular(22),border:Border.all(color:green.withOpacity(.13))),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('إنجاز اليوم',style:TextStyle(color:white,fontWeight:FontWeight.w600)),Text('$done من ${tasks.length}',style:const TextStyle(color:green,fontWeight:FontWeight.bold))]),
        const SizedBox(height:15),
        Row(crossAxisAlignment:CrossAxisAlignment.center,children:[
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('${(pct*100).round()}%',style:const TextStyle(fontSize:34,fontWeight:FontWeight.bold,color:white)),
            const SizedBox(height:4),const Text('كل خطوة صغيرة تصنع فرقاً',style:TextStyle(color:Color(0xFFB4C9BE),fontSize:12)),
          ])),
          SizedBox(width:66,height:66,child:CircularProgressIndicator(value:pct,strokeWidth:7,backgroundColor:Colors.white12,color:green)),
        ]),
      ])),
      const SizedBox(height:24),
      Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
        const Text('مهام اليوم',style:TextStyle(fontSize:19,fontWeight:FontWeight.bold)),
        TextButton(onPressed:widget.onAdd,child:const Text('إضافة مهمة')),
      ]),
      if(tasks.isEmpty) _emptyTasks() else ...tasks.map((t)=>TaskTile(task:t,onChanged:load,onEdit:()=>_addTask(context,widget.selected,load,existing:t))),
      const SizedBox(height:18),
      OutlinedButton.icon(onPressed:widget.onAdd,icon:const Icon(Icons.add),label:const Text('أضف مهمة جديدة'),style:OutlinedButton.styleFrom(foregroundColor:green,side:BorderSide(color:green.withOpacity(.4)),padding:const EdgeInsets.symmetric(vertical:15))),
    ]));
  }
  Widget _emptyTasks()=>Container(padding:const EdgeInsets.all(24),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(18)),child:const Column(children:[Icon(Icons.event_note_outlined,size:36,color:muted),SizedBox(height:10),Text('يومك يبدأ بخطوة',style:TextStyle(fontWeight:FontWeight.bold)),SizedBox(height:5),Text('أضف أول مهمة إلى خطتك اليومية',style:TextStyle(color:muted,fontSize:12))]));
  String _greeting(){final h=DateTime.now().hour;return h<12?'صباح الخير ☀️':h<18?'مساء الخير 🌤':'مساء الخير 🌙';}
}

class TaskTile extends StatelessWidget {
  final RoutineTask task; final VoidCallback onChanged; final VoidCallback? onEdit;
  const TaskTile({super.key,required this.task,required this.onChanged,this.onEdit});
  @override Widget build(BuildContext context)=>Container(margin:const EdgeInsets.only(bottom:9),padding:const EdgeInsets.symmetric(horizontal:13,vertical:12),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(16),border:Border.all(color:task.done?green.withOpacity(.16):Colors.white.withOpacity(.035))),child:Row(children:[
    Checkbox(value:task.done,activeColor:green,checkColor:bg,side:const BorderSide(color:muted),onChanged:(v)async{await AppDb.instance.setDone(task,v??false);onChanged();}),
    const SizedBox(width:6),
    Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(task.title,style:TextStyle(fontWeight:FontWeight.w600,decoration:task.done?TextDecoration.lineThrough:null,color:task.done?muted:white)),
      if(task.description.isNotEmpty)Text(task.description,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:muted,fontSize:11)),
      const SizedBox(height:4),Text('${task.category}${task.time==null?'':'  •  ${task.time}'}',style:const TextStyle(color:muted,fontSize:10)),
    ])),
    if(onEdit!=null)IconButton(onPressed:onEdit,icon:const Icon(Icons.more_horiz,color:muted)),
  ]));
}

class CalendarPage extends StatefulWidget {
  final DateTime selected;final ValueChanged<DateTime> onSelect;final VoidCallback onAdd;
  const CalendarPage({super.key,required this.selected,required this.onSelect,required this.onAdd});
  @override State<CalendarPage> createState()=>_CalendarPageState();
}
class _CalendarPageState extends State<CalendarPage>{
  DateTime month=DateTime(DateTime.now().year,DateTime.now().month);
  Map<String,List<RoutineTask>> cache={};
  @override void initState(){super.initState();load();}
  Future<void> load()async{final all=await AppDb.instance.allTasks();cache={};for(final t in all){cache.putIfAbsent(t.date,()=>[]).add(t);}if(mounted)setState((){});}
  @override Widget build(BuildContext context){
    final first=DateTime(month.year,month.month,1);final days=DateTime(month.year,month.month+1,0).day;
    final offset=(first.weekday)%7;
    return ListView(padding:const EdgeInsets.fromLTRB(18,20,18,100),children:[
      const Text('الخطة الشهرية',style:TextStyle(fontSize:25,fontWeight:FontWeight.bold)),
      const SizedBox(height:5),const Text('نظرة شاملة على أيامك ومهامك',style:TextStyle(color:muted)),
      const SizedBox(height:22),
      Container(padding:const EdgeInsets.all(17),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(20)),child:Column(children:[
        Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
          IconButton(onPressed:()=>setState(()=>month=DateTime(month.year,month.month-1)),icon:const Icon(Icons.chevron_left)),
          Text(DateFormat('MMMM yyyy','ar').format(month),style:const TextStyle(fontWeight:FontWeight.bold,fontSize:17)),
          IconButton(onPressed:()=>setState(()=>month=DateTime(month.year,month.month+1)),icon:const Icon(Icons.chevron_right)),
        ]),
        const SizedBox(height:12),
        Row(children:['أحد','إثن','ثلا','أرب','خمي','جمع','سبت'].map((s)=>Expanded(child:Center(child:Text(s,style:const TextStyle(color:muted,fontSize:11))))).toList()),
        const SizedBox(height:10),
        GridView.builder(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),itemCount:offset+days,gridDelegate:const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount:7,mainAxisSpacing:8,crossAxisSpacing:4),itemBuilder:(ctx,i){
          if(i<offset)return const SizedBox();
          final d=i-offset+1;final date=DateTime(month.year,month.month,d);final key=dayKey(date);final list=cache[key]??[];final completed=list.where((t)=>t.done).length;final isSelected=dayKey(date)==dayKey(widget.selected);
          return InkWell(borderRadius:BorderRadius.circular(12),onTap:()=>widget.onSelect(date),child:Container(decoration:BoxDecoration(color:isSelected?green.withOpacity(.17):Colors.transparent,borderRadius:BorderRadius.circular(12),border:isSelected?Border.all(color:green):null),child:Column(mainAxisAlignment:MainAxisAlignment.center,children:[
            Text('$d',style:TextStyle(color:isSelected?green:white,fontWeight:isSelected?FontWeight.bold:FontWeight.normal)),
            const SizedBox(height:4),
            if(list.isNotEmpty)Container(width:5,height:5,decoration:BoxDecoration(shape:BoxShape.circle,color:completed==list.length?green:Colors.amber)),
          ])));
        }),
      ])),
      const SizedBox(height:18),
      Text('مهام ${DateFormat('d MMMM','ar').format(widget.selected)}',style:const TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      const SizedBox(height:10),
      FutureBuilder<List<RoutineTask>>(future:AppDb.instance.tasksFor(widget.selected),builder:(ctx,s){
        if(!s.hasData)return const Center(child:CircularProgressIndicator());
        if(s.data!.isEmpty)return const Text('لا توجد مهام لهذا اليوم بعد.',style:TextStyle(color:muted));
        return Column(children:s.data!.map((t)=>TaskTile(task:t,onChanged:load,onEdit:()=>_addTask(context,widget.selected,load,existing:t))).toList());
      }),
      const SizedBox(height:10),FilledButton.icon(onPressed:widget.onAdd,icon:const Icon(Icons.add),label:const Text('إضافة مهمة لهذا اليوم')),
    ]);
  }
}

class TasksPage extends StatefulWidget{final VoidCallback onChanged;const TasksPage({super.key,required this.onChanged});@override State<TasksPage> createState()=>_TasksPageState();}
class _TasksPageState extends State<TasksPage>{
  List<RoutineTask> tasks=[];String filter='الكل';
  @override void initState(){super.initState();load();}
  Future<void> load()async{tasks=await AppDb.instance.allTasks();if(mounted)setState((){});}
  @override Widget build(BuildContext context){
    final filtered=tasks.where((t)=>filter=='الكل'||(filter=='مكتملة'?t.done:!t.done)).toList();
    return ListView(padding:const EdgeInsets.fromLTRB(18,20,18,100),children:[
      const Text('مهامي',style:TextStyle(fontSize:25,fontWeight:FontWeight.bold)),const SizedBox(height:5),const Text('كل ما خططت لإنجازه، في مكان واحد',style:TextStyle(color:muted)),
      const SizedBox(height:20),
      SegmentedButton<String>(segments:const [ButtonSegment(value:'الكل',label:Text('الكل')),ButtonSegment(value:'معلقة',label:Text('قيد التنفيذ')),ButtonSegment(value:'مكتملة',label:Text('مكتملة'))],selected:{filter},onSelectionChanged:(v)=>setState(()=>filter=v.first),style:ButtonStyle(visualDensity:VisualDensity.compact)),
      const SizedBox(height:16),
      if(filtered.isEmpty)const Padding(padding:EdgeInsets.all(30),child:Center(child:Text('لا توجد مهام هنا حالياً',style:TextStyle(color:muted))))
      else ...filtered.map((t)=>Dismissible(key:ValueKey(t.id),direction:DismissDirection.endToStart,background:Container(alignment:Alignment.centerLeft,padding:const EdgeInsets.only(left:20),margin:const EdgeInsets.only(bottom:8),decoration:BoxDecoration(color:Colors.red.shade900,borderRadius:BorderRadius.circular(16)),child:const Icon(Icons.delete_outline)),confirmDismiss:(_)=>showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('حذف المهمة؟'),content:Text('هل تريد حذف «${t.title}»؟'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),TextButton(onPressed:()=>Navigator.pop(c,true),child:const Text('حذف'))])).then((v)=>v??false),onDismissed:(_)async{await AppDb.instance.delete(t.id!);load();widget.onChanged();},child:TaskTile(task:t,onChanged:load,onEdit:()=>_addTask(context,DateTime.parse(t.date),load,existing:t)))),
    ]);
  }
}

class ProgressPage extends StatefulWidget{const ProgressPage({super.key});@override State<ProgressPage> createState()=>_ProgressPageState();}
class _ProgressPageState extends State<ProgressPage>{
  List<RoutineTask> tasks=[];@override void initState(){super.initState();load();}
  Future<void> load()async{tasks=await AppDb.instance.allTasks();if(mounted)setState((){});}
  @override Widget build(BuildContext context){
    final now=DateTime.now();final monthTasks=tasks.where((t)=>t.date.startsWith(monthKey(now))).toList();final done=monthTasks.where((t)=>t.done).length;final pending=monthTasks.length-done;final pct=monthTasks.isEmpty?0.0:done/monthTasks.length;
    final last7=List.generate(7,(i)=>DateTime(now.year,now.month,now.day).subtract(Duration(days:6-i)));
    return ListView(padding:const EdgeInsets.fromLTRB(18,20,18,100),children:[
      const Text('إنجازاتي',style:TextStyle(fontSize:25,fontWeight:FontWeight.bold)),const SizedBox(height:5),const Text('تقدمك هو نتيجة خطواتك الصغيرة',style:TextStyle(color:muted)),
      const SizedBox(height:22),
      Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(20)),child:Column(children:[
        const Text('إنجاز هذا الشهر',style:TextStyle(color:muted)),const SizedBox(height:16),
        SizedBox(width:130,height:130,child:Stack(alignment:Alignment.center,children:[SizedBox.expand(child:CircularProgressIndicator(value:pct,strokeWidth:10,backgroundColor:panel2,color:green)),Column(mainAxisAlignment:MainAxisAlignment.center,children:[Text('${(pct*100).round()}%',style:const TextStyle(fontSize:30,fontWeight:FontWeight.bold)),const Text('مكتمل',style:TextStyle(color:muted,fontSize:11))])])),
        const SizedBox(height:20),Row(children:[_stat('المهام الكلية','${monthTasks.length}'),_stat('مكتملة','$done'),_stat('متبقية','$pending')]),
      ])),
      const SizedBox(height:22),const Text('آخر 7 أيام',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),const SizedBox(height:14),
      Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(18)),child:Row(crossAxisAlignment:CrossAxisAlignment.end,mainAxisAlignment:MainAxisAlignment.spaceBetween,children:last7.map((d){
        final dayTasks=tasks.where((t)=>t.date==dayKey(d)).toList();final c=dayTasks.where((t)=>t.done).length;final v=dayTasks.isEmpty?0.0:c/dayTasks.length;
        return Column(children:[SizedBox(height:100,width:23,child:Align(alignment:Alignment.bottomCenter,child:Container(height:8+v*75,width:19,decoration:BoxDecoration(color:green.withOpacity(dayTasks.isEmpty?.22:1),borderRadius:BorderRadius.circular(8))))),const SizedBox(height:8),Text(DateFormat('E','ar').format(d),style:const TextStyle(color:muted,fontSize:10))]);
      }).toList())),
      const SizedBox(height:20),const Text('استمر على وتيرتك',style:TextStyle(fontWeight:FontWeight.bold,fontSize:18)),const SizedBox(height:7),const Text('الاستمرارية لا تعني الكمال؛ المهم أن تعود إلى خطتك كل يوم.',style:TextStyle(color:muted,height:1.6)),
    ]);
  }
  Widget _stat(String label,String value)=>Expanded(child:Column(children:[Text(value,style:const TextStyle(fontWeight:FontWeight.bold,fontSize:21,color:green)),const SizedBox(height:4),Text(label,style:const TextStyle(fontSize:11,color:muted))]));
}

class SettingsPage extends StatefulWidget{const SettingsPage({super.key});@override State<SettingsPage> createState()=>_SettingsPageState();}
class _SettingsPageState extends State<SettingsPage>{
  bool enabled=true,includeTasks=false;int start=8,end=22,frequency=1;
  @override void initState(){super.initState();load();}
  Future<void> load()async{final p=await SharedPreferences.getInstance();setState((){enabled=p.getBool('reminders')??true;includeTasks=p.getBool('includeTasks')??false;start=p.getInt('startHour')??8;end=p.getInt('endHour')??22;frequency=p.getInt('frequency')??1;});}
  Future<void> save()async{final p=await SharedPreferences.getInstance();await p.setBool('reminders',enabled);await p.setBool('includeTasks',includeTasks);await p.setInt('startHour',start);await p.setInt('endHour',end);await p.setInt('frequency',frequency);await ReminderService.instance.reschedule();}
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.fromLTRB(18,20,18,100),children:[
    const Text('الإعدادات',style:TextStyle(fontSize:25,fontWeight:FontWeight.bold)),const SizedBox(height:5),const Text('تحكم في تجربتك مع روتين',style:TextStyle(color:muted)),
    const SizedBox(height:22),Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(18)),child:Column(children:[
      SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('التذكيرات الدورية',style:TextStyle(fontWeight:FontWeight.w600)),subtitle:const Text('ذكّرني بمراجعة مهامي خلال اليوم',style:TextStyle(color:muted,fontSize:12)),value:enabled,activeColor:green,onChanged:(v)async{setState(()=>enabled=v);await save();}),
      const Divider(color:panel2),ListTile(contentPadding:EdgeInsets.zero,title:const Text('بداية التذكير'),subtitle:Text('${start.toString().padLeft(2,'0')}:00',style:const TextStyle(color:green)),trailing:DropdownButton<int>(value:start,dropdownColor:panel2,items:List.generate(24,(i)=>DropdownMenuItem(value:i,child:Text('${i.toString().padLeft(2,'0')}:00'))),onChanged:enabled?(v)async{if(v!=null&&v<=end){setState(()=>start=v);await save();}}:null)),
      ListTile(contentPadding:EdgeInsets.zero,title:const Text('نهاية التذكير'),subtitle:Text('${end.toString().padLeft(2,'0')}:00',style:const TextStyle(color:green)),trailing:DropdownButton<int>(value:end,dropdownColor:panel2,items:List.generate(24,(i)=>DropdownMenuItem(value:i,child:Text('${i.toString().padLeft(2,'0')}:00'))),onChanged:enabled?(v)async{if(v!=null&&v>=start){setState(()=>end=v);await save();}}:null)),
      ListTile(contentPadding:EdgeInsets.zero,title:const Text('تكرار الإشعار'),subtitle:const Text('الفاصل بين التذكيرات',style:TextStyle(color:muted,fontSize:12)),trailing:DropdownButton<int>(value:frequency,dropdownColor:panel2,items:const [DropdownMenuItem(value:1,child:Text('كل ساعة')),DropdownMenuItem(value:2,child:Text('كل ساعتين')),DropdownMenuItem(value:3,child:Text('كل 3 ساعات'))],onChanged:enabled?(v)async{if(v!=null){setState(()=>frequency=v);await save();}}:null)),
      const Divider(color:panel2),SwitchListTile(contentPadding:EdgeInsets.zero,title:const Text('تضمين المهام المتبقية'),subtitle:const Text('يعرض عدد المهام المتبقية في الإشعار',style:TextStyle(color:muted,fontSize:12)),value:includeTasks,activeColor:green,onChanged:enabled?(v)async{setState(()=>includeTasks=v);await save();}:null),
    ])),
    const SizedBox(height:18),Container(padding:const EdgeInsets.all(16),decoration:BoxDecoration(color:panel,borderRadius:BorderRadius.circular(18)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('إدارة الخطة',style:TextStyle(fontWeight:FontWeight.bold)),const SizedBox(height:8),
      ListTile(contentPadding:EdgeInsets.zero,leading:const Icon(Icons.restart_alt,color:Colors.orange),title:const Text('إعادة ضبط الشهر الحالي'),subtitle:const Text('حذف جميع مهام هذا الشهر نهائياً',style:TextStyle(color:muted,fontSize:11)),onTap:()async{final ok=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('إعادة ضبط الشهر؟'),content:const Text('سيتم حذف جميع مهام الشهر الحالي ولا يمكن التراجع.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),TextButton(onPressed:()=>Navigator.pop(c,true),child:const Text('حذف'))]));if(ok==true){await AppDb.instance.resetMonth(DateTime.now());if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تمت إعادة ضبط الخطة')));}}),
    ])),
    const SizedBox(height:18),const Center(child:Text('ROUTINE • روتين  1.0.0',style:TextStyle(color:muted,fontSize:11))),
  ]);
}
