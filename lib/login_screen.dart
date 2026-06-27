import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'create_account_screen.dart';
import 'passenger_home_screen.dart';
import 'driver_home_screen.dart';
import 'db.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (!_tabController.indexIsChanging) setState(() {});
      });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _isPassenger => _tabController.index == 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),

              // Logo
              Center(
                child: Image.asset(
                  'assets/fast_ride_logo_transparent.png',
                  height: 120,
                ),
              ),

              const SizedBox(height: 32),

              const Text(
                'Welcome Back',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: _navy,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Login to your account',
                style: TextStyle(fontSize: 15, color: _navy.withOpacity(0.5)),
              ),

              const SizedBox(height: 24),

              // Tab toggle
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    color: _navy,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  labelColor: Colors.white,
                  unselectedLabelColor: _navy.withOpacity(0.5),
                  labelStyle: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  tabs: const [
                    Tab(text: 'Passenger'),
                    Tab(text: 'Driver'),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Email
              _buildField(
                controller: _emailController,
                hint: 'Email',
                icon: Icons.email_outlined,
              ),

              const SizedBox(height: 16),

              // Password
              _buildField(
                controller: _passwordController,
                hint: 'Password',
                icon: Icons.lock_outline,
                obscure: _obscurePassword,
                suffix: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: _navy.withOpacity(0.5),
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),

              const SizedBox(height: 12),

              // Forgot password
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _showForgotPasswordSheet(context),
                  child: const Text(
                    'Forgot Password?',
                    style: TextStyle(color: _red, fontWeight: FontWeight.w600),
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // Login button
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: _loading ? null : _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _red,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: _red.withOpacity(0.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          'Login',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: _red, fontSize: 13),
                ),
              ],

              // Google button — passenger only
              if (_isPassenger) ...[
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Divider(
                        color: _navy.withOpacity(0.2),
                        thickness: 1,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'or',
                        style: TextStyle(color: _navy.withOpacity(0.4)),
                      ),
                    ),
                    Expanded(
                      child: Divider(
                        color: _navy.withOpacity(0.2),
                        thickness: 1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: OutlinedButton(
                    onPressed: () {},
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      side: BorderSide(color: _navy.withOpacity(0.15)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const FaIcon(FontAwesomeIcons.google, size: 20),
                        const SizedBox(width: 12),
                        const Text(
                          'Continue with Google',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _navy,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),

              // Create account
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Don't have an account? ",
                    style: TextStyle(color: _navy.withOpacity(0.7)),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CreateAccountScreen(),
                      ),
                    ),
                    child: const Text(
                      'Create Account',
                      style: TextStyle(
                        color: _red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please enter your email and password.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (!mounted) return;

      // Verify the role matches the selected tab
      final uid = cred.user!.uid;
      final driverDoc = await db.collection('drivers').doc(uid).get();
      final isDriver = driverDoc.exists;

      if (!mounted) return;

      if (_isPassenger && isDriver) {
        // Driver trying to log in as passenger
        await FirebaseAuth.instance.signOut();
        setState(
          () => _error =
              'This account is a driver account. Please select the Driver tab.',
        );
        return;
      }
      if (!_isPassenger && !isDriver) {
        // Passenger trying to log in as driver
        await FirebaseAuth.instance.signOut();
        setState(
          () => _error =
              'This account is a passenger account. Please select the Passenger tab.',
        );
        return;
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) =>
              isDriver ? const DriverHomeScreen() : const PassengerHomeScreen(),
        ),
      );
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'user-not-found' ||
          'invalid-email' => 'No account found with this email.',
          'wrong-password' ||
          'invalid-credential' => 'Incorrect password. Please try again.',
          'too-many-requests' => 'Too many attempts. Try again later.',
          'user-disabled' => 'This account has been disabled.',
          _ => e.message ?? 'Something went wrong.',
        };
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showForgotPasswordSheet(BuildContext context) {
    final resetEmailController = TextEditingController();
    bool sent = false;
    bool loading = false;
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: _cream,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Reset Password',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: _navy,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter your email and we\'ll send you a reset link.',
                  style: TextStyle(color: _navy.withOpacity(0.6)),
                ),
                const SizedBox(height: 20),
                _buildField(
                  controller: resetEmailController,
                  hint: 'Email',
                  icon: Icons.email_outlined,
                ),
                const SizedBox(height: 12),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: _red, fontSize: 13),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _red.withOpacity(0.4)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: _red,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(fontSize: 13, color: _navy),
                            children: [
                              const TextSpan(text: 'Can\'t find the email? '),
                              TextSpan(
                                text: 'Check your Junk or Spam folder.',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: _red,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: sent || loading
                        ? null
                        : () async {
                            final email = resetEmailController.text.trim();
                            if (email.isEmpty) {
                              setSheetState(
                                () => error = 'Please enter your email.',
                              );
                              return;
                            }
                            setSheetState(() {
                              loading = true;
                              error = null;
                            });
                            try {
                              await FirebaseAuth.instance
                                  .sendPasswordResetEmail(email: email);
                              setSheetState(() {
                                sent = true;
                                loading = false;
                              });
                            } on FirebaseAuthException catch (e) {
                              setSheetState(() {
                                loading = false;
                                error = e.code == 'user-not-found'
                                    ? 'No account found with this email.'
                                    : e.message ?? 'Something went wrong.';
                              });
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _red,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: _red.withOpacity(0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : Text(
                            sent ? 'Email Sent ✓' : 'Send Reset Link',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      style: const TextStyle(color: _navy),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _navy.withOpacity(0.4)),
        prefixIcon: Icon(icon, color: _navy.withOpacity(0.5)),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
