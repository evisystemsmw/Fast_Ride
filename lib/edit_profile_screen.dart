import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'db.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

const _navy = Color(0xFF143B58);
const _red = Color(0xFFC53E21);
const _cream = Color(0xFFF7EAD9);

class EditProfileScreen extends StatefulWidget {
  final String name;
  final String phone;
  final String? photoUrl;
  final bool isDriver;

  const EditProfileScreen({
    super.key,
    this.name = '',
    this.phone = '',
    this.photoUrl,
    this.isDriver = false,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  File? _pickedImage;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
    _phoneController = TextEditingController(text: widget.phone);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );
    if (picked != null) setState(() => _pickedImage = File(picked.path));
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    if (name.isEmpty || phone.isEmpty) {
      setState(() => _error = 'Name and phone cannot be empty.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      String? photoUrl = widget.photoUrl;

      if (_pickedImage != null) {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse('https://api.cloudinary.com/v1_1/dldlyioii/image/upload'),
        );
        request.fields['upload_preset'] = 'fastrider_profiles';
        request.fields['folder'] = widget.isDriver ? 'drivers' : 'passengers';
        request.fields['public_id'] =
            '${uid}_${DateTime.now().millisecondsSinceEpoch}';
        request.files.add(
          await http.MultipartFile.fromPath('file', _pickedImage!.path),
        );
        final res = await request.send();
        final body = jsonDecode(await res.stream.bytesToString());
        if (body['secure_url'] == null) {
          throw Exception('Upload failed: ${body['error']?['message']}');
        }
        photoUrl = body['secure_url'] as String;
      }

      final collection = widget.isDriver ? 'drivers' : 'users';
      await db.collection(collection).doc(uid).update({
        'name': name,
        'phone': phone,
        'photoUrl': ?photoUrl,
      });

      await FirebaseAuth.instance.currentUser!.updateDisplayName(name);

      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = 'Failed to update profile. Try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
          'Edit Profile',
          style: TextStyle(color: _navy, fontWeight: FontWeight.bold),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          children: [
            const SizedBox(height: 24),

            // Avatar picker
            Center(
              child: GestureDetector(
                onTap: _pickImage,
                child: Stack(
                  children: [
                    Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _navy.withOpacity(0.1),
                        border: Border.all(
                          color: _navy.withOpacity(0.2),
                          width: 2,
                        ),
                        image: _pickedImage != null
                            ? DecorationImage(
                                image: FileImage(_pickedImage!),
                                fit: BoxFit.cover,
                              )
                            : widget.photoUrl != null
                            ? DecorationImage(
                                image: NetworkImage(widget.photoUrl!),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: (_pickedImage == null && widget.photoUrl == null)
                          ? Center(
                              child: Text(
                                widget.name.isNotEmpty
                                    ? widget.name[0].toUpperCase()
                                    : '?',
                                style: const TextStyle(
                                  fontSize: 38,
                                  fontWeight: FontWeight.bold,
                                  color: _navy,
                                ),
                              ),
                            )
                          : null,
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: _red,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              'Tap to change photo',
              style: TextStyle(fontSize: 12, color: _navy.withOpacity(0.4)),
            ),

            const SizedBox(height: 32),

            _field(_nameController, 'Full Name', Icons.person_outline),
            const SizedBox(height: 16),
            _field(
              _phoneController,
              'Phone Number',
              Icons.phone_outlined,
              keyboardType: TextInputType.phone,
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: _red, fontSize: 13)),
            ],

            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _loading ? null : _save,
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
                        'Save Changes',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String hint,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      style: const TextStyle(color: _navy),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _navy.withOpacity(0.4)),
        prefixIcon: Icon(icon, color: _navy.withOpacity(0.5)),
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
