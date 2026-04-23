import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart'; // Ensure this file exists and contains LoginScreen

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController(initialPage: 0);
  int _currentPage = 0;
  bool isArabic = true;

  final List<Map<String, dynamic>> onboardingData = [
    {
      "titleAr": "مرحباً بك في راصد",
      "titleEn": "Welcome to Rased",
      "descAr": "رفيقك على الطريق لقيادة أكثر أماناً وذكاءً. حافظ على سلامتك، وساهم في تحسين طرق مدينتك.",
      "descEn": "Your companion for safer and smarter driving. Stay safe and help improve your city's roads.",
      "icon": Icons.directions_car_filled_outlined,
    },
    {
      "titleAr": "رصد آلي لعيوب الطريق",
      "titleEn": "Automated Road Damage Detection",
      "descAr": "يقوم التطبيق برصد الحفر، المناهل المكسورة، والتشققات تلقائياً باستخدام الذكاء الاصطناعي لتوفير طرق أكثر أماناً.",
      "descEn": "The app automatically detects potholes, broken manholes, and cracks using AI to ensure safer roads.",
      "icon": Icons.add_road,
    },
    {
      "titleAr": "تصوير يدوي ورفع بلاغات",
      "titleEn": "Manual Detection & Upload",
      "descAr": "يمكنك أيضاً تصوير عيوب الطريق يدوياً ورفعها مباشرة من خلال الكاميرا لضمان وصول صوتك.",
      "descEn": "You can also manually photograph road defects and upload them directly via camera to ensure your report is heard.",
      "icon": Icons.camera_enhance_outlined,
    },
    {
      "titleAr": "تتبع تقاريرك",
      "titleEn": "Track Your Reports",
      "descAr": "راقب حالة تقاريرك حول عيوب الطريق وتلقّ إشعارات عند معالجتها من قبل الجهات المختصة.",
      "descEn": "Monitor the status of your road damage reports and receive notifications when authorities address them.",
      "icon": Icons.assignment_turned_in_outlined,
    },
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('has_seen_onboarding', true);
    
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                child: Align(
                  alignment: isArabic ? Alignment.centerLeft : Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => isArabic = !isArabic),
                    child: Text(
                      isArabic ? "English" : "العربية",
                      style: const TextStyle(color: Color(0xFFFFD700), fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (int page) => setState(() => _currentPage = page),
                  itemCount: onboardingData.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 40.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Spacer(),
                          Icon(
                            onboardingData[index]["icon"],
                            size: 150,
                            color: const Color(0xFFFFD700),
                          ),
                          const SizedBox(height: 60),
                          Text(
                            isArabic ? onboardingData[index]["titleAr"] : onboardingData[index]["titleEn"],
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            isArabic ? onboardingData[index]["descAr"] : onboardingData[index]["descEn"],
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 15, color: Colors.white70, height: 1.5),
                          ),
                          const Spacer(flex: 2),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: _completeOnboarding,
                      child: Text(
                        isArabic ? "تخطي" : "Skip",
                        style: const TextStyle(color: Colors.white54, fontSize: 16),
                      ),
                    ),
                    Row(
                      children: List.generate(
                        onboardingData.length,
                        (index) => _buildDot(index: index),
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD700),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                      ),
                      onPressed: () {
                        if (_currentPage == onboardingData.length - 1) {
                          _completeOnboarding();
                        } else {
                          _pageController.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.ease,
                          );
                        }
                      },
                      child: Text(
                        _currentPage == onboardingData.length - 1 
                            ? (isArabic ? "تم" : "Done") 
                            : (isArabic ? "التالي" : "Next"),
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDot({required int index}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(right: 5),
      height: 8,
      width: _currentPage == index ? 24 : 8,
      decoration: BoxDecoration(
        color: _currentPage == index ? const Color(0xFFFFD700) : Colors.white24,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}