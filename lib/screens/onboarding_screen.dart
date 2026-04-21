import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'login_screen.dart'; // Make sure this imports your actual login/home screen!

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController(initialPage: 0);
  int _currentPage = 0;

  // The accurate data for the 3 onboarding screens
  final List<Map<String, dynamic>> onboardingData = [
    {
      "title": "مرحباً بك في راصد",
      "description": "رفيقك على الطريق لقيادة أكثر أماناً وذكاءً. حافظ على سلامتك، وساهم في تحسين طرق مدينتك.",
      "icon": Icons.directions_car_filled_outlined, 
    },
    {
      "title": "رصد آلي لعيوب الطريق",
      "description": "يقوم التطبيق برصد الحفر، المناهل المكسورة، والتشققات تلقائياً باستخدام الذكاء الاصطناعي لتوفير طرق أكثر أماناً.",
      "icon": Icons.add_road, 
    },
    {
      "title": "تتبع تقاريرك",
      "description": "راقب حالة تقاريرك حول عيوب الطريق وتلقّ إشعارات عند معالجتها من قبل الجهات المختصة.",
      "icon": Icons.assignment_turned_in_outlined,
    },
  ];

  // Call this when the user finishes onboarding
  Future<void> _completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hasSeenOnboarding', true);

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LoginScreen()),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF121212), // 🚨 Matched to your app's Dark Theme background
        body: SafeArea(
          child: Column(
            children: [
              // --- TOP BAR (Language) ---
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    "العربية",
                    style: TextStyle(
                      color: Color(0xFFFFD700), // 🚨 Rased Yellow
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),

              // --- PAGE VIEW (Swipeable Content) ---
              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (int page) {
                    setState(() {
                      _currentPage = page;
                    });
                  },
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
                            color: const Color(0xFFFFD700), // 🚨 Rased Yellow
                          ),
                          const SizedBox(height: 60),
                          Text(
                            onboardingData[index]["title"],
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white, // 🚨 White for contrast
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            onboardingData[index]["description"],
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 15,
                              color: Colors.white70, // 🚨 Subtle white/grey
                              height: 1.5,
                            ),
                          ),
                          const Spacer(flex: 2),
                        ],
                      ),
                    );
                  },
                ),
              ),

              // --- BOTTOM NAVIGATION BAR ---
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 24.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // SKIP BUTTON
                    TextButton(
                      onPressed: _completeOnboarding,
                      child: const Text(
                        "تخطي",
                        style: TextStyle(color: Colors.white54, fontSize: 16),
                      ),
                    ),

                    // DOT INDICATORS
                    Row(
                      children: List.generate(
                        onboardingData.length,
                        (index) => _buildDot(index: index),
                      ),
                    ),

                    // NEXT / DONE BUTTON
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFD700), // 🚨 Yellow Button
                        foregroundColor: Colors.black, // 🚨 Black Text for readability
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
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
                        _currentPage == onboardingData.length - 1 ? "تم" : "التالي",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
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

  // Animated Dot Builder
  Widget _buildDot({required int index}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(right: 5),
      height: 8,
      width: _currentPage == index ? 24 : 8,
      decoration: BoxDecoration(
        color: _currentPage == index ? const Color(0xFFFFD700) : Colors.white24, // 🚨 Active is Yellow
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}