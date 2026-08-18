# SmartBrain — دماغ الروبوت (مجلس الخبراء)

## شو بيعمل
كل 15 دقيقة، 24/7، بيقرأ: التقويم الاقتصادي (ForexFactory)، آخر عناوين الأخبار (اقتصاد، بنوك مركزية، حروب/كوارث، ذهب، نفط، بورصات)، وبيعقد "مجلس خبراء" (8 شخصيات: اقتصادي، مراقب بنوك مركزية، محلل جيوسياسي، استراتيجي عملات، تاجر ذهب/نفط، مكتب مخاطر/بورصة، مدير مخاطر، رئيس المجلس) بيتناقشوا وبيطلّعوا **توجيهات نهائية** بملف `brain.txt`.
الروبوت SmartMulti_v11 على الـVPS بيقرأ الملف كل 5 دقايق وبيطبّق التوجيهات على كل الكتب.

## التركيب (مرة وحدة، ~10 دقايق)
1. اعمل حساب GitHub (مجاني) إذا ما عندك → أنشئ repo **Public** اسمو `smartbrain`.
2. حمّل هالملفات فيه: `brain.py`, `.github/workflows/brain.yml`, `README_AR.md`.
3. Settings → Secrets and variables → Actions → New repository secret:
   - Name: `ANTHROPIC_API_KEY`  Value: مفتاح من https://console.anthropic.com (كلفة تقريبية 3–10$ بالشهر).
   (اختياري) Variable `BRAIN_MODEL` = `claude-sonnet-4-5`.
4. Actions → SmartBrain council → Run workflow (أول تشغيل يدوي)، بعدها بيشتغل لحالو كل 15 دقيقة.
5. رابط الملف بيصير: `https://raw.githubusercontent.com/<USERNAME>/smartbrain/main/brain.txt`
6. بالـMT5: Tools → Options → Expert Advisors → ✔ Allow WebRequest → أضف `https://raw.githubusercontent.com` — بعدها Synchronize للـVPS.
7. حط الرابط بخانة `InpBrainURL` بالروبوت v11.

## أمان
- إذا الملف قديم (أكتر من 45 دقيقة) أو ما وصل → الروبوت بيتجاهل الدماغ وبيرجع لمنطقو العادي (fail-safe).
- الدماغ ما بيقدر يفتح صفقة لحالو؛ بس بيوجّه: يوقف، يخفّف، يمنع اتجاه، يفعّل محرّك الصدمة (والصدمة لازم يأكّدها السعر).
