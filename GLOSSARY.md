# College Academic Bot

A shared Telegram bot and Mini App that manages academic files, assignments, attendance, exams, grievances, and community participation across a university college.

## Language

### Organization & Groups

**College** *(الكلية)*:
The top-level academic institution (for example, the College of Computer Science & IT) containing multiple **Majors** under one shared deployment.
_Avoid_: Faculty, university, organization

**Major** *(التخصص)*:
An academic specialization within a **College**, such as Information Technology, Computer Science, Cybersecurity, AI, Graphics, or Information Systems.
_Avoid_: Department, track, branch, specialization

**Cohort** *(الدفعة)*:
A specific batch and academic level of students within a **Major** (for example, IT Batch 3, Level 3).
_Avoid_: Class, year, batch, intake

**Theory Group** *(المجموعة النظرية)*:
A lecture section within a **Cohort** (such as `IT3_G1` through `IT3_G4`) that owns one or more **Practical Groups**.
_Avoid_: Section, lecture group, main group

**Practical Group** *(المجموعة العملية)*:
A lab sub-group (such as `G1` through `G8`) belonging to exactly one **Theory Group**.
_Avoid_: Lab, subgroup, tutorial group

### People & Access

**User** *(المستخدم)*:
Any Telegram account that has interacted with the bot or Mini App, classified as new, guest *(زائر)*, or linked **Student**.
_Avoid_: Account, member, profile

**Student** *(الطالب)*:
An enrolled learner identified by an academic number and assigned to one **Theory Group** and one **Practical Group**, optionally linked to a **User**.
_Avoid_: Learner, pupil, enrolled user

**Doctor** *(الدكتور / المعيد)*:
A faculty member or teaching assistant who teaches one or more **Subjects** and receives assignment submissions for their assigned groups.
_Avoid_: Instructor, professor, lecturer, teacher

**Role Grant** *(منحة الدور)*:
An active assignment of a role (`deputy` *(نائب مندوب)*, `delegate` *(مندوب مجموعة)*, `committee` *(عضو لجنة علمية)*, or `developer` *(مطوّر)*) to a **User**.
_Avoid_: Role assignment, privilege, membership

**Permission** *(الصلاحية)*:
A named capability granted to a role (such as uploading **Files** or opening an **Attendance Session**), optionally constrained by scope or condition.
_Avoid_: Right, access flag, rule

### Academic Catalog & Routing

**Subject** *(المادة)*:
A course taught in a **Cohort**, identified by its Arabic name and hashtag.
_Avoid_: Course, module, class

**Teaching** *(التدريس)*:
The binding that records which **Doctor** teaches the theory or practical part of a **Subject** for a specific **Theory Group** or **Practical Group**.
_Avoid_: Course assignment, schedule entry, allocation

**Telegram Destination** *(وجهة تيليجرام)*:
A mapped Telegram chat (and optional forum topic) where **Files**, notices, or **Doctor** submissions for a **Subject** or group are routed.
_Avoid_: Channel, chat target, group link, topic mapping

### Academic Workflows

**File** *(الملف الدراسي)*:
A lecture, summary, or study document stored on Telegram and indexed under a **Subject**, **Doctor**, and group for **Users** to browse and retrieve.
_Avoid_: Attachment, document, resource, upload

**Assignment** *(الواجب)*:
A graded task for a **Subject** and group to which **Students** submit attachments or text before a deadline, and which a **Doctor** can mark as received.
_Avoid_: Homework, task, submission item

**Attendance Session** *(جلسة الحضور)*:
A timed lecture check-in window for a **Theory Group** where a delegate or deputy records **Student** presence via barcode scan.
_Avoid_: Roll call, check-in, lecture session

**Grievance** *(التظلم)*:
A formal grade or academic complaint submitted by a **Student** during an open grievance cycle for their **Theory Group**.
_Avoid_: Appeal, complaint, dispute, ticket

**Sharek** *(شارك)*:
A community campaign where **Students** submit study contributions or media and vote on submissions within their group.
_Avoid_: Contest, community post, feed

**MCQ** *(اختبار الاختيار من متعدد)*:
A multiple-choice practice quiz for a **Subject** that **Users** can take in the Mini App or via interactive Telegram polls.
_Avoid_: Quiz, exam, test bank

**Outbox** *(صندوق الصادر)*:
A durable queue of outbound Telegram notifications and messages delivered asynchronously to respect Telegram rate limits.
_Avoid_: Message queue, notification buffer, job queue

**Activity Log** *(سجل النشاط)*:
An append-only audit trail recording who performed sensitive administrative or academic actions and on which entity.
_Avoid_: Audit log, history, event log

### Multi-Tenancy

**Tenant Scope Node** *(عقدة النطاق)*:
A single node in the **Scope Tree** representing a **College**, **Major**, **Cohort**, **Theory Group**, or **Practical Group** that owns data or limits access.
_Avoid_: Tenant, org unit, namespace

**Scope Tree** *(شجرة النطاق)*:
The five-level hierarchy `College → Major → Cohort → Theory Group → Practical Group` used to isolate tenant data and inherit administrative powers downward.
_Avoid_: Org chart, hierarchy, tenant tree

**Scoped Role Grant** *(منحة دور بنطاق)*:
A **Role Grant** bound to a specific **Tenant Scope Node**; powers inherit to all descendant nodes, and one **User** may hold multiple grants.
_Avoid_: Regional role, nested permission, scoped admin

**College Admin** *(مشرف الكلية)*:
A **User** holding a **Scoped Role Grant** at the **College** node, with management authority across all **Majors** and **Cohorts**.
_Avoid_: Superadmin, global admin, root

**Major Admin** *(مشرف التخصص)*:
A **User** holding a **Scoped Role Grant** at a **Major** node (such as Information Technology), with management authority across all **Cohorts** and groups within that **Major**.
_Avoid_: Department head, track admin, branch admin

**Cohort Admin** *(مشرف الدفعة)*:
A **User** holding a **Scoped Role Grant** at a **Cohort** node (such as IT Level 3), managing only that **Cohort** and its groups.
_Avoid_: Year admin, sub-admin

**Group Rep** *(مندوب المجموعة)*:
A **User** holding a **Scoped Role Grant** at a **Theory Group** or **Practical Group** node, managing only their assigned group.
_Avoid_: Class rep, leader, sub-delegate
