import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _cream,
      appBar: AppBar(
        backgroundColor: _cream,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: _navy),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Create Account',
          style: TextStyle(color: _navy, fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
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
          ),
          const SizedBox(height: 24),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                _RegisterForm(role: 'passenger'),
                _RegisterForm(role: 'driver'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RegisterForm extends StatefulWidget {
  final String role;
  const _RegisterForm({required this.role});

  @override
  State<_RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<_RegisterForm> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _idNumberController = TextEditingController();
  final _licenceController = TextEditingController();
  final _carModelController = TextEditingController();
  final _plateController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscure = true;
  bool _obscureConfirm = true;
  bool _passwordsMatch = false;
  bool _loading = false;
  String? _error;

  bool get _isDriver => widget.role == 'driver';

  void _onPasswordChanged() {
    setState(() {
      _passwordsMatch =
          _passwordController.text.isNotEmpty &&
          _passwordController.text == _confirmPasswordController.text;
    });
  }

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_onPasswordChanged);
    _confirmPasswordController.addListener(_onPasswordChanged);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _idNumberController.dispose();
    _licenceController.dispose();
    _carModelController.dispose();
    _plateController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    final password = _passwordController.text.trim();

    if (name.isEmpty || email.isEmpty || phone.isEmpty || password.isEmpty) {
      setState(() => _error = 'Please fill in all fields.');
      return;
    }
    if (_isDriver &&
        (_idNumberController.text.trim().isEmpty ||
            _licenceController.text.trim().isEmpty ||
            _carModelController.text.trim().isEmpty ||
            _plateController.text.trim().isEmpty)) {
      setState(() => _error = 'Please fill in all driver fields.');
      return;
    }
    if (!_passwordsMatch) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final credential = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);

      await credential.user!.updateDisplayName(name);

      final Map<String, dynamic> userData = {
        'name': name,
        'email': email,
        'phone': phone,
        'role': widget.role,
        'createdAt': FieldValue.serverTimestamp(),
        'signupCompleted': false,
        if (_isDriver) ...{
          'status': 'pending',
          'isOnline': false,
          'firstLoginDone': false,
        },
      };

      if (_isDriver) {
        userData.addAll({
          'driverIdNumber': _idNumberController.text.trim(),
          'licenseNumber': _licenceController.text.trim(),
          'vehicleMake': _carModelController.text.trim(),
          'numberPlate': _plateController.text.trim(),
        });
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(credential.user!.uid)
          .set(userData);

      // Also write to drivers collection so auth gate routes correctly
      if (_isDriver) {
        await FirebaseFirestore.instance
            .collection('drivers')
            .doc(credential.user!.uid)
            .set(userData);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account created successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
        // TODO: navigate to home screen
      }
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'email-already-in-use' =>
            'An account already exists with this email.',
          'weak-password' => 'Password must be at least 6 characters.',
          'invalid-email' => 'Please enter a valid email address.',
          _ => e.message ?? 'Something went wrong.',
        };
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          _field(_nameController, 'Full Name', Icons.person_outline),
          const SizedBox(height: 16),
          _field(
            _emailController,
            'Email',
            Icons.email_outlined,
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          _field(
            _phoneController,
            'Phone Number',
            Icons.phone_outlined,
            keyboardType: TextInputType.phone,
          ),
          if (_isDriver) ...[
            const SizedBox(height: 16),
            _field(_idNumberController, 'ID Number', Icons.badge_outlined),
            const SizedBox(height: 16),
            _field(
              _licenceController,
              'Licence Number',
              Icons.credit_card_outlined,
            ),
            const SizedBox(height: 16),
            _field(
              _carModelController,
              'Car Model',
              Icons.directions_car_outlined,
            ),
            const SizedBox(height: 16),
            _field(
              _plateController,
              'Vehicle Plate Number',
              Icons.pin_outlined,
            ),
          ],
          const SizedBox(height: 16),
          _field(
            _passwordController,
            'Password',
            Icons.lock_outline,
            obscure: _obscure,
            suffix: IconButton(
              icon: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: _navy.withOpacity(0.5),
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 16),
          _field(
            _confirmPasswordController,
            'Confirm Password',
            Icons.lock_outline,
            obscure: _obscureConfirm,
            suffix: _passwordsMatch
                ? const Icon(Icons.check_circle, color: Colors.green)
                : IconButton(
                    icon: Icon(
                      _obscureConfirm
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: _navy.withOpacity(0.5),
                    ),
                    onPressed: () =>
                        setState(() => _obscureConfirm = !_obscureConfirm),
                  ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: _red, fontSize: 13)),
          ],
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: _loading ? null : _signup,
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
                  : Text(
                      'Create ${_isDriver ? 'Driver' : 'Passenger'} Account',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
          if (!_isDriver) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Divider(color: _navy.withOpacity(0.2), thickness: 1),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'or',
                    style: TextStyle(color: _navy.withOpacity(0.4)),
                  ),
                ),
                Expanded(
                  child: Divider(color: _navy.withOpacity(0.2), thickness: 1),
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
                  children: const [
                    FaIcon(FontAwesomeIcons.google, size: 20),
                    SizedBox(width: 12),
                    Text(
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
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String hint,
    IconData icon, {
    bool obscure = false,
    Widget? suffix,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
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
